import 'dart:async'; // <-- IMPORTANTE para StreamSubscription
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'hive_helper.dart';

class LupaEmpresaScreen extends StatefulWidget {
  final Map<String, dynamic> empresa;
  final String bearerToken; // token que llega desde EmpresaScreen, pero NO se usará en requests
  final String idEmpresaAsociada;
  final String empresaId;
  final bool openScannerOnInit;

  const LupaEmpresaScreen({
    Key? key,
    required this.empresa,
    required this.bearerToken,
    required this.idEmpresaAsociada,
    required this.empresaId,
    this.openScannerOnInit = false,
  }) : super(key: key);

  @override
  _LupaEmpresaScreenState createState() => _LupaEmpresaScreenState();
}

class _LupaEmpresaScreenState extends State<LupaEmpresaScreen> {
  String? selectedContractor;
  String? selectedContractorCuit;
  String? selectedContractorTipo;
  String? selectedContractorMensajeGeneral;
  String? selectedContractorEstado;
  bool showContractorInfo = false;
  bool showEmployees = false;
  List<dynamic> empleados = [];
  List<dynamic> filteredEmpleados = [];
  List<dynamic> allEmpleados = [];
  List<dynamic> allFetchedEmpleados = [];
  bool isLoading = true;

  final MobileScannerController controladorCamara = MobileScannerController();
  final TextEditingController personalIdController = TextEditingController();
  final TextEditingController dominioController = TextEditingController();
  final TextEditingController searchController = TextEditingController();

  bool qrScanned = false;
  bool? resultadoHabilitacion;

  late Dio dio;
  late CookieJar cookieJar;
  late Connectivity connectivity;
  late StreamSubscription<ConnectivityResult> connectivitySubscription;

  String hiveIdUsuarios = '';

  // Mapa para almacenar si un empleado está actualmente dentro (true) o fuera (false).
  Map<String, bool> employeeInsideStatus = {};

  @override
  void initState() {
    super.initState();

    cookieJar = CookieJar();
    dio = Dio();
    dio.interceptors.add(CookieManager(cookieJar));

    connectivity = Connectivity();
    connectivitySubscription = connectivity.onConnectivityChanged.listen((ConnectivityResult result) {
      if (result != ConnectivityResult.none) {
        _processPendingRequests();
      }
    });

    hiveIdUsuarios = HiveHelper.getIdUsuarios();

    // NO guardamos token en variable. Se obtendrá directamente de Hive en cada request
    searchController.addListener(_filterEmployees);

    obtenerEmpleados().then((_) {
      if (widget.openScannerOnInit) {
        _mostrarEscanerQR();
      }
    });
  }

  @override
  void dispose() {
    controladorCamara.dispose();
    personalIdController.dispose();
    dominioController.dispose();
    searchController.dispose();
    connectivitySubscription.cancel();
    super.dispose();
  }

  void _mostrarProximamente() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Próximamente', style: TextStyle(fontFamily: 'Montserrat')),
          content: const Text('Esta funcionalidad estará disponible próximamente.', style: TextStyle(fontFamily: 'Montserrat')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK', style: TextStyle(fontFamily: 'Montserrat')),
            ),
          ],
        );
      },
    );
  }

  void updateSelectedContractor(String nombreRazonSocial) {
    setState(() {
      final contractorLower = nombreRazonSocial.trim().toLowerCase();
      selectedContractor = nombreRazonSocial.trim();

      // IMPORTANTE: Limpiamos la lista anterior de empleados y forzamos a que
      // el usuario deba volver a presionar el botón Empleados.
      showEmployees = false;
      allFetchedEmpleados.clear();
      empleados.clear();
      filteredEmpleados.clear();

      var empleadoSeleccionado = allEmpleados.firstWhere(
        (empleado) => (empleado['nombre_razon_social']?.toString().trim().toLowerCase() == contractorLower),
        orElse: () => null,
      );
      selectedContractorCuit = empleadoSeleccionado != null ? empleadoSeleccionado['cuit'] : '';
      selectedContractorTipo = empleadoSeleccionado != null ? empleadoSeleccionado['tipo'] : '';
      selectedContractorMensajeGeneral = empleadoSeleccionado != null ? empleadoSeleccionado['mensaje_general'] : '';
      selectedContractorEstado = empleadoSeleccionado != null ? empleadoSeleccionado['estado'] : '';

      showContractorInfo = true;
    });
  }

  Future<void> _saveOfflineRequest(String dniIngresado) async {
    final Map<String, dynamic> pendingData = {
      "dni": dniIngresado,
      "id_empresas": widget.empresaId,
      "id_usuarios": hiveIdUsuarios,
      "timestamp": DateTime.now().toIso8601String(),
    };
    HiveHelper.savePendingDNIRequest(pendingData);
  }

  Future<void> _processPendingRequests() async {
    final List<Map<String, dynamic>> pendingRequests = HiveHelper.getAllPendingDNIRequests();
    if (pendingRequests.isEmpty) return;

    for (var requestData in pendingRequests) {
      final String dniIngresado = requestData["dni"] ?? '';
      final String idEmpresas = requestData["id_empresas"] ?? '';
      final String idUsuarios = requestData["id_usuarios"] ?? '';

      if (dniIngresado.isEmpty) continue;

      try {
        // Para cada GET, tomamos el token fresco de Hive
        final response = await _makeGetRequest(
          "https://www.infocontrol.tech/web/api/mobile/empleados/listartest",
          queryParameters: {'id_empresas': idEmpresas},
        );

        final statusCode = response.statusCode ?? 0;
        if (statusCode == 200) {
          final responseData = response.data;
          List<dynamic> employeesData = responseData['data'] ?? [];
          final foundEmployee = employeesData.firstWhere(
            (emp) => emp['valor']?.toString().trim() == dniIngresado,
            orElse: () => null,
          );
          if (foundEmployee != null) {
            final String idEntidad = foundEmployee['id_entidad'] ?? 'NO DISPONIBLE';
            final String estado = foundEmployee['estado']?.toString().trim() ?? '';
            if (estado.toLowerCase() == 'inhabilitado') {
              continue;
            }

            final Map<String, dynamic> postData = {
              'id_empresas': idEmpresas,
              'id_usuarios': idUsuarios,
              'id_entidad': idEntidad,
            };

            final postResponse = await _makePostRequest(
              "https://www.infocontrol.tech/web/api/mobile/Ingresos_egresos/register_movement",
              postData,
            );

            if ((postResponse.statusCode ?? 0) == 200) {
              HiveHelper.removePendingDNIRequest(requestData);
            }
          }
        }
      } catch (e) {
        // Error procesando pendiente offline
      }
    }
  }

  Future<void> _hacerIngresoEgresoEmpleado(dynamic empleado) async {
    final estado = (empleado['estado']?.toString().trim() ?? '').toLowerCase();
    if (estado == 'inhabilitado') {
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Empleado Inhabilitado'),
            content: const Text('No se puede hacer el ingreso o egreso para este empleado.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      return;
    }

    final dniVal = (empleado['valor']?.toString().trim() ?? '');
    if (dniVal.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se encontró DNI del empleado.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final connectivityResult = await connectivity.checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      await _saveOfflineRequest(dniVal);
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Modo offline'),
            content: const Text('Se guardó para registrar cuando vuelva la conexión.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      return;
    }

    final String idEntidad = empleado['id_entidad'] ?? 'NO DISPONIBLE';
    await _registerMovement(idEntidad);
  }

  Future<void> _buscarPersonalId() async {
    final texto = personalIdController.text.trim();
    if (texto.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Falta informacion en el campo'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final connectivityResult = await connectivity.checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      await _saveOfflineRequest(texto);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Modo offline'),
            content: const Text('Se guardó para registrar cuando vuelva la conexión.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      return;
    }

    // Mostrar "Cargando..."
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text(
                'Cargando...',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 16,
                  color: Colors.black,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      final response = await _makeGetRequest(
        "https://www.infocontrol.tech/web/api/mobile/empleados/listartest",
        queryParameters: {'id_empresas': widget.empresaId},
      );

      Navigator.pop(context);
      final statusCode = response.statusCode ?? 0;

      if (statusCode == 200) {
        final responseData = response.data;
        List<dynamic> employeesData = responseData['data'] ?? [];
        final String dniIngresado = texto;

        final foundEmployee = employeesData.firstWhere(
          (emp) => emp['valor']?.toString().trim() == dniIngresado,
          orElse: () => null,
        );

        if (foundEmployee != null) {
          _showEmpleadoDetailsModal(foundEmployee);
        } else {
          showDialog(
            context: context,
            builder: (ctx) {
              return AlertDialog(
                title: const Text('No encontrado'),
                content: const Text('No se encontró el DNI en la respuesta.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('OK'),
                  ),
                ],
              );
            },
          );
        }
      } else {
        // statusCode != 200
        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Código de respuesta'),
              content: Text('El código de respuesta es: $statusCode'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    } on DioException catch (e) {
      Navigator.pop(context);
      if (e.response?.statusCode == 401) {
        // Si el token no es válido, mostramos un SnackBar para indicarle al usuario
        // que vaya a HomeScreen, el cual maneja la lógica de refresco de token.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Token inválido. Vuelva a HomeScreen para recargar.')),
        );
      } else {
        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Error'),
              content: Text('Error en la solicitud: $e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      Navigator.pop(context);
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Error inesperado'),
            content: Text('Ocurrió un error: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> _registerMovement(String idEntidad) async {
    // Mostrar "Cargando..."
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text(
                'Cargando...',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 16,
                  color: Colors.black,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      final Map<String, dynamic> postData = {
        'id_empresas': widget.empresaId,
        'id_usuarios': hiveIdUsuarios,
        'id_entidad': idEntidad,
      };

      final postResponse = await _makePostRequest(
        "https://www.infocontrol.tech/web/api/mobile/Ingresos_egresos/register_movement",
        postData,
      );

      Navigator.pop(context);

      final int statusCode = postResponse.statusCode ?? 0;
      final dynamic fullResponse = postResponse.data;

      if (statusCode == 200) {
        final dynamic dataObject = fullResponse['data'] ?? {};
        final String messageToShow = dataObject['message'] ?? 'Mensaje no disponible';

        bool isInside = employeeInsideStatus[idEntidad] ?? false;
        employeeInsideStatus[idEntidad] = !isInside;

        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Respuesta exitosa'),
              content: Text(messageToShow),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      } else {
        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: Text('Código de respuesta: $statusCode'),
              content: Text('Respuesta completa:\n${fullResponse.toString()}'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    } on DioException catch (e) {
      Navigator.pop(context);
      if (e.response?.statusCode == 401) {
        // Token inválido
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Token inválido en POST. Vuelva a HomeScreen para recargar.')),
        );
      } else {
        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Error al registrar movimiento'),
              content: Text('Error en la solicitud POST: ${e.toString()}'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      Navigator.pop(context);
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Error inesperado'),
            content: Text('Ocurrió un error en POST: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    }
  }

  void _reIniciarPaginaYEscanear() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => LupaEmpresaScreen(
          empresa: widget.empresa,
          bearerToken: widget.bearerToken, // se pasa el que venía, pero no se usa en requests
          idEmpresaAsociada: widget.idEmpresaAsociada,
          empresaId: widget.empresaId,
          openScannerOnInit: true,
        ),
      ),
    );
  }

  Future<void> _buscarDominio() async {
    final texto = dominioController.text.trim();
    if (texto.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Falta informacion en el campo'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Mostrar "Cargando..."
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text(
                'Cargando...',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 16,
                  color: Colors.black,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      final connectivityResult = await connectivity.checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        Navigator.pop(context);
        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Modo offline'),
              content: const Text('No hay conexión para solicitar datos del dominio.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
        return;
      }

      // Token fresco de Hive
      final response = await _makeGetRequest(
        "https://www.infocontrol.tech/web/api/mobile/empleados/listartest",
        queryParameters: {'id_empresas': widget.empresaId},
      );

      Navigator.pop(context);
      final statusCode = response.statusCode ?? 0;
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Código de respuesta'),
            content: Text('El código de respuesta es: $statusCode'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    } on DioException catch (e) {
      Navigator.pop(context);
      if (e.response?.statusCode == 401) {
        // Manejo de 401 - Avisamos al usuario
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Token inválido en GET. Vuelva a HomeScreen para recargar.')),
        );
      } else {
        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Error'),
              content: Text('Error en la solicitud: $e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      Navigator.pop(context);
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Error inesperado'),
            content: Text('Ocurrió un error: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    }
  }

  /// IMPORTANTE:
  /// Si hay conexión, hacemos la solicitud y guardamos la lista en Hive,
  /// usando como key "empresaId + contractorLower".
  /// Si NO hay conexión, se muestra la lista que tenemos guardada en Hive (si existe).
  Future<void> _fetchEmpleadosAPI() async {
    if (selectedContractor == null || selectedContractor!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Debes elegir un contratista'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final contractorLower = selectedContractor!.trim().toLowerCase();

    // Primero revisamos la conectividad
    final connectivityResult = await connectivity.checkConnectivity();

    // Si NO hay conexión, buscamos en Hive directamente
    if (connectivityResult == ConnectivityResult.none) {
      // Obtenemos la lista local de ESTE contratista
      List<dynamic> localEmpleados = HiveHelper.getContratistaEmpleados(widget.empresaId, contractorLower);

      if (localEmpleados.isNotEmpty) {
        setState(() {
          allFetchedEmpleados = localEmpleados;
          empleados = localEmpleados;
          filteredEmpleados = localEmpleados;
          showEmployees = true;
        });
      } else {
        // Si no hay datos locales, avisamos que no está disponible offline
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No hay datos locales de este contratista.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Si SÍ hay conexión, mostramos el diálogo de "Cargando"
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text(
                'Cargando...',
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 16,
                  color: Colors.black,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      // Token fresco de Hive
      final response = await _makeGetRequest(
        "https://www.infocontrol.tech/web/api/mobile/empleados/listartest",
        queryParameters: {'id_empresas': widget.empresaId},
      );

      Navigator.pop(context);
      final statusCode = response.statusCode ?? 0;

      if (statusCode == 200) {
        final responseData = response.data;
        List<dynamic> empleadosData = responseData['data'] ?? [];

        // FILTRAMOS los empleados que corresponden a ESTE contratista
        List<dynamic> filtrados = empleadosData
            .where((emp) => (emp['nombre_razon_social']?.toString().trim().toLowerCase() == contractorLower))
            .toList();

        // Guardamos la lista de ESTE contratista en Hive
        await HiveHelper.insertContratistaEmpleados(widget.empresaId, contractorLower, filtrados);

        setState(() {
          allFetchedEmpleados = filtrados;
          empleados = filtrados;
          filteredEmpleados = filtrados;
          showEmployees = true;
        });
      } else {
        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Código de respuesta'),
              content: Text('El código de respuesta es: $statusCode'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    } on DioException catch (e) {
      Navigator.pop(context);
      if (e.response?.statusCode == 401) {
        // Token inválido
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Token inválido en Empleados. Vuelva a HomeScreen para recargar.')),
        );
      } else {
        showDialog(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Error'),
              content: Text('Error en la solicitud: $e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      Navigator.pop(context);
      showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Error inesperado'),
            content: Text('Ocurrió un error: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    }
  }

  /// Método original para obtener la lista general de empleados (proveedores)
  Future<void> obtenerEmpleados() async {
    var connectivityResult = await connectivity.checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      List<dynamic> empleadosLocales = HiveHelper.getEmpleados(widget.empresaId);
      if (empleadosLocales.isNotEmpty) {
        allEmpleados = empleadosLocales;
        setState(() {
          isLoading = false;
        });
      } else {
        setState(() {
          isLoading = false;
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No hay datos locales disponibles para empleados.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else {
      try {
        // Token fresco de Hive
        final response = await _makeGetRequest(
          'https://www.infocontrol.tech/web/api/mobile/proveedores/listar',
          queryParameters: {
            'id_empresas': widget.idEmpresaAsociada,
          },
        );

        if (response.statusCode == 200) {
          final responseData = response.data;
          allEmpleados = responseData['data'] ?? [];
          await HiveHelper.insertEmpleados(widget.empresaId, allEmpleados);
          setState(() {
            isLoading = false;
          });
        } else {
          setState(() {
            isLoading = false;
          });
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al obtener empleados: ${response.statusCode}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } on DioException catch (e) {
        setState(() {
          isLoading = false;
        });
        if (!mounted) return;
        if (e.response?.statusCode == 401) {
          // Token inválido
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Token inválido en ObtenerEmpleados. Vuelva a HomeScreen para recargar.')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error en la solicitud: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (e) {
        setState(() {
          isLoading = false;
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error en la solicitud: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _filterEmployees() {
    String query = searchController.text.toLowerCase().trim();
    if (query.isEmpty) {
      setState(() {
        filteredEmpleados = List.from(empleados);
      });
    } else {
      List<dynamic> temp = [];
      for (var empleado in empleados) {
        final dniVal = (empleado['valor']?.toString().trim() ?? '').toLowerCase();
        if (dniVal.startsWith(query)) {
          temp.add(empleado);
        }
      }
      setState(() {
        filteredEmpleados = temp;
      });
    }
  }

  void _mostrarEscanerQR() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.8,
          child: Column(
            children: [
              AppBar(
                backgroundColor: const Color(0xFF2a3666),
                title: const Text(
                  'Escanear QR',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    color: Colors.white,
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.flash_on, color: Colors.white),
                    onPressed: () => controladorCamara.toggleTorch(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.flip_camera_android, color: Colors.white),
                    onPressed: () => controladorCamara.switchCamera(),
                  ),
                ],
              ),
              Expanded(
                child: MobileScanner(
                  controller: controladorCamara,
                  onDetect: (captura) {
                    final List<Barcode> codigosBarras = captura.barcodes;
                    if (codigosBarras.isNotEmpty) {
                      final String codigo = codigosBarras.first.rawValue ?? '';
                      Navigator.pop(context);

                      try {
                        final qrData = jsonDecode(codigo);
                        final entidad = qrData['entidad'];

                        if (entidad == 'empleado') {
                          final dni = qrData['dni'] ?? 'DNI no disponible';
                          personalIdController.text = dni;
                        } else if (entidad == 'vehiculo') {
                          final dominio = qrData['dominio'] ?? 'Dominio no disponible';
                          dominioController.text = dominio;
                        }
                        setState(() {
                          qrScanned = true;
                        });
                      } catch (_) {}
                    }
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<String> _getContractorsForDropdown() {
    Set<String> contractors = {};
    for (var emp in allEmpleados) {
      final nombre = emp['nombre_razon_social']?.toString().trim() ?? '';
      if (nombre.isNotEmpty) {
        contractors.add(nombre);
      }
    }
    List<String> sorted = contractors.toList();
    sorted.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  /// NUEVA FUNCIÓN para pedir la acción (ingreso/egreso) al endpoint action_resource
  Future<String> _fetchActionResource(String idEntidad) async {
    try {
      final postData = {"id_entidad": idEntidad};
      final response = await _makePostRequest(
        "https://www.infocontrol.tech/web/api/mobile/ingresos_egresos/action_resource",
        postData,
      );

      if ((response.statusCode ?? 0) == 200) {
        final respData = response.data ?? {};
        final data = respData['data'] ?? {};
        final message = data['message'] ?? '';
        return message;
      } else {
        return '';
      }
    } catch (e) {
      // Manejo de error, si deseas puedes retornar algo por defecto
      return '';
    }
  }

  // AHORA MARCAMOS _showEmpleadoDetailsModal COMO ASYNC PARA AÑADIR LA LLAMADA A _fetchActionResource
  Future<void> _showEmpleadoDetailsModal(dynamic empleado) async {
    final estado = (empleado['estado']?.toString().trim() ?? '').toLowerCase();
    final bool isHabilitado = estado == 'habilitado';
    final bool contractorIsHabilitado = selectedContractorEstado?.trim().toLowerCase() == 'habilitado';

    final datosString = empleado['datos']?.toString() ?? '';
    String apellidoVal = '';
    String nombreVal = '';
    String dniVal = (empleado['valor']?.toString().trim() ?? '');

    if (datosString.isNotEmpty && datosString.startsWith('[') && datosString.endsWith(']')) {
      try {
        List datosList = jsonDecode(datosString);
        var apellidoMap = datosList.firstWhere(
          (item) => item['id'] == "Apellido:",
          orElse: () => null,
        );
        var nombreMap = datosList.firstWhere(
          (item) => item['id'] == "Nombre:",
          orElse: () => null,
        );

        apellidoVal = (apellidoMap != null && apellidoMap['valor'] is String)
            ? (apellidoMap['valor'] as String).trim()
            : '';
        nombreVal = (nombreMap != null && nombreMap['valor'] is String)
            ? (nombreMap['valor'] as String).trim()
            : '';
      } catch (_) {}
    }

    final displayName = (apellidoVal.isEmpty && nombreVal.isEmpty)
        ? "No disponible"
        : "$apellidoVal $nombreVal";

    final contratistaSeleccionado = selectedContractor ?? 'No disponible';
    final String idEntidad = empleado['id_entidad'] ?? 'NO DISPONIBLE';
    bool isInside = employeeInsideStatus[idEntidad] ?? false;

    // Esto era el texto original para ingreso/egreso, lo mantendremos por defecto
    String buttonText = isInside ? 'Marcar egreso' : 'Marcar ingreso';

    // SOLO si el empleado y contratista están habilitados, pedimos la acción al nuevo endpoint
    if (isHabilitado && contractorIsHabilitado) {
      final actionMessage = await _fetchActionResource(idEntidad);
      if (actionMessage == "REGISTRAR INGRESO") {
        buttonText = "Registrar Ingreso";
      } else if (actionMessage == "REGISTRAR EGRESO") {
        buttonText = "Registrar Egreso";
      }
    }

    // NUEVO: si el contratista está INHABILITADO, aunque el empleado esté habilitado, no se debe mostrar botón.
    bool showActionButton = false; 
    if (isHabilitado && contractorIsHabilitado) {
      showActionButton = true;
    }

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          content: SingleChildScrollView(
            child: Column(
              children: [
                Image.asset('assets/generic.jpg', width: 80, height: 80),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  decoration: BoxDecoration(
                    color: isHabilitado ? Colors.green : Colors.red,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isHabilitado ? 'HABILITADO' : 'INHABILITADO',
                    style: const TextStyle(
                      fontFamily: 'Montserrat',
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nombre: $displayName',
                      style: const TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 14,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Dni: $dniVal',
                      style: const TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 14,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Contratista: $contratistaSeleccionado',
                      style: const TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 14,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cerrar', style: TextStyle(fontFamily: 'Montserrat')),
            ),
            // Ahora mostramos el botón de acción (ingresar/egresar) 
            // solo si el empleado está habilitado y el contratista también
            if (showActionButton)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _hacerIngresoEgresoEmpleado(empleado);
                },
                child: Text(buttonText, style: const TextStyle(fontFamily: 'Montserrat')),
              ),
          ],
        );
      },
    );
  }

  // Cada GET/POST obtiene el token fresco de Hive
  Future<Response> _makeGetRequest(String url, {Map<String, dynamic>? queryParameters}) async {
    String freshToken = HiveHelper.getBearerToken();
    return await dio.get(
      Uri.parse(url).replace(queryParameters: queryParameters).toString(),
      options: Options(
        headers: {
          'Authorization': 'Bearer $freshToken',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ),
    );
  }

  Future<Response> _makePostRequest(String url, Map<String, dynamic> data) async {
    String freshToken = HiveHelper.getBearerToken();
    return await dio.post(
      url,
      data: jsonEncode(data),
      options: Options(
        headers: {
          'Authorization': 'Bearer $freshToken',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String botonQrText = qrScanned ? "Ingresar con otro QR" : "Ingreso con QR";

    List<String> contractorItems = _getContractorsForDropdown();

    bool isContratistaHabilitado = false;
    if (selectedContractorEstado != null) {
      final estado = selectedContractorEstado!.trim().toLowerCase();
      isContratistaHabilitado = estado == 'habilitado';
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF2a3666)),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: Color(0xFF2a3666)),
            onPressed: () {},
          ),
          Container(
            height: 24,
            width: 1,
            color: Colors.grey[300],
            margin: const EdgeInsets.symmetric(horizontal: 10),
          ),
          CircleAvatar(
            backgroundColor: const Color(0xFF232e63),
            radius: 15,
            child: Text(
              widget.empresa['nombre']?[0] ?? 'E',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          const SizedBox(width: 5),
          const Icon(Icons.arrow_drop_down, color: Color(0xFF232e63)),
          const SizedBox(width: 10),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Container(
                color: const Color(0xFFe6e6e6),
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.empresa['nombre'] ?? 'Nombre no disponible',
                            style: const TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 18,
                              color: Color(0xFF7e8e95),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Divider(color: Colors.grey[300], thickness: 1),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFe0f7fa),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              "Complete alguno de los filtros para obtener resultados. Puede buscar por contratista, empleado, vehículo o maquinaria",
                              style: TextStyle(
                                fontFamily: 'Montserrat',
                                fontSize: 14,
                                color: Colors.black,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 30),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Filtros de Búsquedas',
                            style: TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 18,
                              color: Color(0xFF7e8e95),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Divider(color: Colors.grey[300], thickness: 1),
                          const SizedBox(height: 20),
                          const Text(
                            'Contratista',
                            style: TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 16,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            items: contractorItems.map<DropdownMenuItem<String>>((nombreRazonSocial) {
                              return DropdownMenuItem<String>(
                                value: nombreRazonSocial,
                                child: Text(
                                  nombreRazonSocial,
                                  style: const TextStyle(fontFamily: 'Montserrat'),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              );
                            }).toList(),
                            value: selectedContractor,
                            onChanged: (value) {
                              if (value != null) {
                                updateSelectedContractor(value);
                              }
                            },
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
                              hintText: 'Seleccione Contratista',
                              hintStyle: const TextStyle(
                                fontFamily: 'Montserrat',
                                color: Colors.grey,
                              ),
                              filled: true,
                              fillColor: Colors.grey[200],
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Número de Identificación Personal',
                            style: TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 16,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '(Sin puntos ni guiones)',
                            style: TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: personalIdController,
                                  decoration: InputDecoration(
                                    hintText: 'Número de Identificación Personal',
                                    hintStyle: const TextStyle(
                                      fontFamily: 'Montserrat',
                                      color: Colors.grey,
                                    ),
                                    filled: true,
                                    fillColor: Colors.grey[200],
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF43b6ed),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.search, color: Colors.white),
                                  onPressed: _buscarPersonalId,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Dominio/Placa/N° de Serie/N° de Chasis',
                            style: TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 16,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '(Sin espacios ni guiones)',
                            style: TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: dominioController,
                                  decoration: InputDecoration(
                                    hintText: 'DOMINIO EJ: ABC123',
                                    hintStyle: const TextStyle(
                                      fontFamily: 'Montserrat',
                                      color: Colors.grey,
                                    ),
                                    filled: true,
                                    fillColor: Colors.grey[200],
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF43b6ed),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.search, color: Colors.white),
                                  onPressed: _buscarDominio,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (resultadoHabilitacion != null) ...[
                            const SizedBox(height: 16),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: resultadoHabilitacion! ? Colors.green[300] : Colors.red[300],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: Text(
                                  resultadoHabilitacion! ? 'HABILITADO' : 'INHABILITADO',
                                  style: const TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontSize: 16,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            if (resultadoHabilitacion! == false) ...[
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _mostrarProximamente,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.grey[300],
                                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(Icons.warning, color: Colors.black54),
                                      SizedBox(width: 8),
                                      Text(
                                        'Marcar ingreso con excepción',
                                        style: TextStyle(color: Colors.black54),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () {
                                if (qrScanned) {
                                  _reIniciarPaginaYEscanear();
                                } else {
                                  _mostrarEscanerQR();
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00BCD4),
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.qr_code_scanner, color: Colors.white, size: 24),
                                  const SizedBox(width: 8),
                                  Text(
                                    botonQrText,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      fontFamily: 'Montserrat',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (showContractorInfo) ...[
                            const SizedBox(height: 30),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    selectedContractor ?? 'Empresa',
                                    style: const TextStyle(
                                      fontFamily: 'Montserrat',
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF232e5f),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: isContratistaHabilitado ? Colors.green[300] : Colors.red[300],
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Center(
                                      child: Text(
                                        isContratistaHabilitado
                                            ? 'CONTRATISTA HABILITADO'
                                            : 'CONTRATISTA INHABILITADO',
                                        style: const TextStyle(
                                          fontFamily: 'Montserrat',
                                          fontSize: 16,
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  Text(
                                    'Razón Social: ${selectedContractor ?? 'No disponible'}',
                                    style: const TextStyle(
                                      fontFamily: 'Montserrat',
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text('CUIT: ${selectedContractorCuit ?? 'No disponible'}'),
                                  const Text('Tipo persona: -'),
                                  Text('Tipo trabajador: ${selectedContractorTipo ?? 'No disponible'}'),
                                  const Text('Actividades: -'),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 30),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _fetchEmpleadosAPI,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.grey[200],
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(Icons.people, color: Colors.black54),
                                      SizedBox(width: 8),
                                      Text(
                                        'Empleados',
                                        style: TextStyle(color: Colors.black54),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _mostrarProximamente,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.grey[200],
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(Icons.directions_car, color: Colors.black54),
                                      SizedBox(width: 8),
                                      Text(
                                        'Vehículos',
                                        style: TextStyle(color: Colors.black54),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Center(
                            child: ElevatedButton(
                              onPressed: _mostrarProximamente,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey[300],
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(Icons.print, color: Colors.black54),
                                  SizedBox(width: 8),
                                  Text(
                                    'Imprimir',
                                    style: TextStyle(color: Colors.black54),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (showEmployees) ...[
                            const SizedBox(height: 30),
                            TextField(
                              controller: searchController,
                              decoration: InputDecoration(
                                hintText: 'Buscar por DNI',
                                hintStyle: const TextStyle(
                                  fontFamily: 'Montserrat',
                                  color: Colors.grey,
                                ),
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Colors.grey, width: 1),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Colors.grey, width: 1),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Colors.blue, width: 1),
                                ),
                                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                              ),
                            ),
                            const SizedBox(height: 20),
                            if (filteredEmpleados.isNotEmpty) ...[
                              for (var empleado in filteredEmpleados)
                                Builder(builder: (context) {
                                  final datosString = empleado['datos']?.toString() ?? '';
                                  String displayName = 'No disponible';
                                  String apellidoVal = '';
                                  String nombreVal = '';
                                  String dniVal = (empleado['valor']?.toString().trim() ?? '');

                                  if (datosString.isNotEmpty &&
                                      datosString.startsWith('[') &&
                                      datosString.endsWith(']')) {
                                    try {
                                      List datosList = jsonDecode(datosString);
                                      var apellidoMap = datosList.firstWhere(
                                        (item) => item['id'] == "Apellido:",
                                        orElse: () => null,
                                      );
                                      var nombreMap = datosList.firstWhere(
                                        (item) => item['id'] == "Nombre:",
                                        orElse: () => null,
                                      );

                                      apellidoVal = (apellidoMap != null && apellidoMap['valor'] is String)
                                          ? (apellidoMap['valor'] as String).trim()
                                          : '';
                                      nombreVal = (nombreMap != null && nombreMap['valor'] is String)
                                          ? (nombreMap['valor'] as String).trim()
                                          : '';

                                      if (apellidoVal.isEmpty && nombreVal.isEmpty) {
                                        displayName = "No disponible";
                                      } else {
                                        displayName = "$apellidoVal $nombreVal - $dniVal".trim();
                                      }
                                    } catch (_) {
                                      displayName = "No disponible";
                                    }
                                  }

                                  String estado = (empleado['estado']?.toString().trim() ?? '').toLowerCase();
                                  Color textColor = estado == 'habilitado' ? Colors.green : Colors.red;

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            displayName,
                                            style: TextStyle(
                                              fontFamily: 'Montserrat',
                                              fontSize: 16,
                                              color: textColor,
                                              decoration: TextDecoration.none,
                                            ),
                                          ),
                                        ),
                                        ElevatedButton(
                                          onPressed: () => _showEmpleadoDetailsModal(empleado),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(0xFF43b6ed),
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            minimumSize: const Size(60, 30),
                                          ),
                                          child: const Text(
                                            'Consultar',
                                            style: TextStyle(color: Colors.white, fontSize: 12),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                })
                            ] else ...[
                              const Text(
                                'No hay empleados.',
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontSize: 16,
                                  color: Colors.black,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ]
                          ]
                        ],
                      ),
                    ),
                    const SizedBox(height: 30),
                    Center(
                      child: Image.asset(
                        'assets/infocontrol_logo.png',
                        width: 150,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
