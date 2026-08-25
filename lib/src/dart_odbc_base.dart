// ignore_for_file: lines_longer_than_80_chars

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_odbc/dart_odbc.dart';
import 'package:dart_odbc/src/libodbcext.dart';
import 'package:ffi/ffi.dart';

/// Safer, more defensive DartOdbc wrapper.
/// Key fixes:
///  - use calloc<T>() consistently
///  - keep handles valid until disconnected
///  - use nullptr (not null) for Pointer checks
///  - use SQL_NTS for string lengths to avoid inconsistent length math
///  - correct diagnostics allocations (SQLGetDiagRecW)
class DartOdbc {
  factory DartOdbc({
    String? dsn,
    String? pathToDriver,
    @Deprecated('Is not used anymore') int? version,
    @Deprecated('Not used') UtfType utfType = UtfType.utf16,
  }) =>
      DartOdbc._internal(dsn: dsn, pathToDriver: pathToDriver, version: version);

  DartOdbc._internal({String? dsn, String? pathToDriver, int? version})
      : _dsn = dsn {
    if (pathToDriver != null) {
      __sql = LibOdbcExt(DynamicLibrary.open(pathToDriver));
    } else {
      if (Platform.isLinux) {
        __sql = LibOdbcExt(DynamicLibrary.open('libodbc.so'));
      } else if (Platform.isWindows) {
        __sql = LibOdbcExt(DynamicLibrary.open('odbc32.dll'));
      } else if (Platform.isMacOS) {
        __sql = LibOdbcExt(DynamicLibrary.open('libodbc.dylib'));
      }
      if (__sql == null) {
        throw ODBCException('ODBC driver not found');
      }
    }

    _initialize(version: version);
  }

  LibOdbc? __sql;
  final String? _dsn;

  /// keep non-nullable pointers but initialized to nullptr
  SQLHANDLE _hEnv = nullptr;
  SQLHDBC _hConn = nullptr;

  LibOdbc get _sql {
    if (__sql != null) return __sql!;
    throw ODBCException('ODBC driver not found');
  }

  void _initialize({int? version}) {
    // allocate environment handle (pointer to SQLHANDLE)
    final pHEnv = calloc<SQLHANDLE>();
    try {
      final rc = _sql.SQLAllocHandle(SQL_HANDLE_ENV, nullptr, pHEnv);
      tryOdbc(rc, operationType: SQL_HANDLE_ENV, handle: pHEnv.value, onException: HandleException());
      _hEnv = pHEnv.value;

      // set ODBC version to 3
      // SQLSetEnvAttr expects SQLPOINTER for attribute value
      final ret1 = _sql.SQLSetEnvAttr(
        _hEnv, SQL_ATTR_ODBC_VERSION,
        Pointer.fromAddress(SQL_OV_ODBC3), // cast int to SQLPOINTER
        0,
      );
      tryOdbc(ret1, handle: _hEnv, operationType: SQL_HANDLE_ENV, onException: HandleException());
    } finally {
      // free the temporary pointer wrapper (not the handle itself)
      calloc.free(pHEnv);
    }
  }

  /// Connect using DSN
  Future<void> connect({
    required String username,
    required String password,
  }) async {
    if (_dsn == null) throw ODBCException('DSN not provided');

    final pHConn = calloc<SQLHDBC>();
    try {
      tryOdbc(
        _sql.SQLAllocHandle(SQL_HANDLE_DBC, _hEnv, pHConn),
        handle: _hEnv,
        operationType: SQL_HANDLE_DBC,
        onException: HandleException(),
      );
      _hConn = pHConn.value;

      // set login timeout (defensive)
      final t = calloc<SQLUINTEGER>()..value = 30;
      try {
        tryOdbc(
          _sql.SQLSetConnectAttr(
            _hConn,
            SQL_LOGIN_TIMEOUT,
            t.cast(),
            0,
          ),
          handle: _hConn,
          operationType: SQL_HANDLE_DBC,
          onException: ConnectionException(),
        );
      } finally {
        calloc.free(t);
      }

      final cDsn = _dsn!.toNativeUtf16().cast<UnsignedShort>();
      final cUsername = username.toNativeUtf16().cast<UnsignedShort>();
      final cPassword = password.toNativeUtf16().cast<UnsignedShort>();

      try {
        tryOdbc(
          _sql.SQLConnectW(
            _hConn,
            cDsn,
            SQL_NTS,
            cUsername,
            SQL_NTS,
            cPassword,
            SQL_NTS,
          ),
          handle: _hConn,
          operationType: SQL_HANDLE_DBC,
          onException: ConnectionException(),
        );
      } finally {
        calloc.free(cDsn);
        calloc.free(cUsername);
        calloc.free(cPassword);
      }
    } catch (e) {
      // if allocation succeeded but connect failed, free the DB handle
      if (_hConn != nullptr) {
        _sql.SQLFreeHandle(SQL_HANDLE_DBC, _hConn);
        _hConn = nullptr;
      }
      rethrow;
    } finally {
      calloc.free(pHConn); // free the temporary pointer wrapper (handle preserved in _hConn)
    }
  }

  /// Connect using connection string (Driver={...};Server=...;UID=...;PWD=...;)
  Future<void> connectWithConnectionString(String connectionString) async {
    final pHConn = calloc<SQLHDBC>();
    try {
      tryOdbc(
        _sql.SQLAllocHandle(SQL_HANDLE_DBC, _hEnv, pHConn),
        handle: _hEnv,
        operationType: SQL_HANDLE_DBC,
        onException: HandleException(),
      );
      _hConn = pHConn.value;

      // set login timeout as a defensive measure
      final t = calloc<SQLUINTEGER>()..value = 30;
      try {
        tryOdbc(
          _sql.SQLSetConnectAttr(
            _hConn,
            SQL_LOGIN_TIMEOUT,
            t.cast(),
            0,
          ),
          handle: _hConn,
          operationType: SQL_HANDLE_DBC,
          onException: ConnectionException(),
        );
      } finally {
        calloc.free(t);
      }

      final cConnectionString = connectionString.toNativeUtf16().cast<UnsignedShort>();
      const outLen = 2048;
      final outConnectionString = calloc<UnsignedShort>(outLen);
      final outConnectionStringLen = calloc<SQLSMALLINT>();

      try {
        tryOdbc(
          _sql.SQLDriverConnectW(
            _hConn,
            nullptr,
            cConnectionString,
            SQL_NTS,
            outConnectionString,
            outLen,
            outConnectionStringLen,
            SQL_DRIVER_NOPROMPT,
          ),
          handle: _hConn,
          operationType: SQL_HANDLE_DBC,
          onException: ConnectionException(),
        );

        final actualLen = outConnectionStringLen.value;
        // if driver returned a length, decode that, otherwise decode up to first NUL
        final resultString = outConnectionString.cast<Utf16>().toDartString(length: actualLen > 0 ? actualLen : null);
        print('Connected! Driver returned connection string: $resultString');
      } finally {
        calloc.free(cConnectionString);
        calloc.free(outConnectionString);
        calloc.free(outConnectionStringLen);
      }
    } catch (e) {
      if (_hConn != nullptr) {
        _sql.SQLFreeHandle(SQL_HANDLE_DBC, _hConn);
        _hConn = nullptr;
      }
      rethrow;
    } finally {
      calloc.free(pHConn);
    }
  }

  Future<List<Map<String, dynamic>>> getTables({
    String? tableName,
    String? catalog,
    String? schema,
    String? tableType,
  }) async {
    final pHStmt = calloc<SQLHSTMT>();
    try {
      tryOdbc(
        _sql.SQLAllocHandle(SQL_HANDLE_STMT, _hConn, pHStmt),
        handle: _hConn,
        onException: HandleException(),
      );
      final hStmt = pHStmt.value;

      final cCatalog = catalog?.toNativeUtf16().cast<UnsignedShort>() ?? nullptr;
      final cSchema = schema?.toNativeUtf16().cast<UnsignedShort>() ?? nullptr;
      final cTableName = tableName?.toNativeUtf16().cast<UnsignedShort>() ?? nullptr;
      final cTableType = tableType?.toNativeUtf16().cast<UnsignedShort>() ?? nullptr;

      try {
        tryOdbc(
          _sql.SQLTablesW(
            hStmt,
            cCatalog,
            SQL_NTS,
            cSchema,
            SQL_NTS,
            cTableName,
            SQL_NTS,
            cTableType,
            SQL_NTS,
          ),
          handle: hStmt,
          onException: FetchException(),
        );

        List<String> tblColTypes = [];
        final result = _getResult(hStmt, {}, tblColTypes);
        return result;
      } finally {
        // free param strings if they were allocated
        if (cCatalog != nullptr) calloc.free(cCatalog);
        if (cSchema != nullptr) calloc.free(cSchema);
        if (cTableName != nullptr) calloc.free(cTableName);
        if (cTableType != nullptr) calloc.free(cTableType);

        _sql.SQLFreeHandle(SQL_HANDLE_STMT, hStmt);
      }
    } finally {
      calloc.free(pHStmt);
    }
  }

  Future<List<Map<String, dynamic>>> execute(
    String query, {
    List<dynamic>? params,
    List<String>? outColTypes,
    Map<String, ColumnType> columnConfig = const {},
  }) async {
    final pHStmt = calloc<SQLHSTMT>();
    try {
      tryOdbc(
        _sql.SQLAllocHandle(SQL_HANDLE_STMT, _hConn, pHStmt),
        handle: _hConn,
        onException: HandleException(),
      );
      final hStmt = pHStmt.value;
      final pointers = <OdbcPointer<dynamic>>[];
      final cQuery = query.toNativeUtf16().cast<UnsignedShort>();

      try {
        if (params != null && params.isNotEmpty) {
          // prepare (use SQL_NTS for null-terminated)
          tryOdbc(
            _sql.SQLPrepareW(hStmt, cQuery.cast(), SQL_NTS),
            handle: hStmt,
            onException: QueryException(),
          );

          for (var i = 0; i < params.length; i++) {
            final param = params[i];
            final cParam = OdbcConversions.toPointer(param);
            pointers.add(cParam);

            tryOdbc(
              _sql.SQLBindParameter(
                hStmt,
                i + 1,
                SQL_PARAM_INPUT,
                OdbcConversions.getCtypeFromType(param.runtimeType),
                OdbcConversions.getSqlTypeFromType(param.runtimeType),
                0,
                0,
                cParam.ptr,
                cParam.length,
                nullptr,
              ),
              handle: hStmt,
            );
          }

          tryOdbc(_sql.SQLExecute(hStmt), handle: hStmt);
        } else {
          // no params — execute SQL directly, length SQL_NTS
          tryOdbc(
            _sql.SQLExecDirectW(hStmt, cQuery.cast(), SQL_NTS),
            handle: hStmt,
          );
        }

        final result = _getResult(hStmt, columnConfig, outColTypes);
        return result;
      } finally {
        // free param pointers and query pointer
        for (final ptr in pointers) {
          ptr.free();
        }
        calloc.free(cQuery);
        _sql.SQLFreeHandle(SQL_HANDLE_STMT, hStmt);
      }
    } finally {
      calloc.free(pHStmt);
    }
  }

  Future<void> disconnect() async {
    // only call disconnect if we have a valid handle
    if (_hConn != nullptr) {
      _sql.SQLDisconnect(_hConn);
      _sql.SQLFreeHandle(SQL_HANDLE_DBC, _hConn);
      _hConn = nullptr;
    }
    if (_hEnv != nullptr) {
      _sql.SQLFreeHandle(SQL_HANDLE_ENV, _hEnv);
      _hEnv = nullptr;
    }
  }

  void tryOdbc(
    int status, {
    SQLHANDLE? handle,
    int operationType = SQL_HANDLE_STMT,
    ODBCException? onException,
  }) {
    if (status == SQL_ERROR || status == SQL_INVALID_HANDLE) {
      onException ??= ODBCException('ODBC error');
      onException.code = status;

      if (handle != null && handle != nullptr) {
        // diagnostics buffers
        const bufferLength = 1024;
        final sqlState = calloc<Uint16>(6).cast<Utf16>();
        final nativeErr = calloc<Int>(); // SQLINTEGER usually 32-bit
        final msg = calloc<Uint16>(bufferLength).cast<Utf16>();
        final textLenPtr = calloc<SQLSMALLINT>();

        try {
          var recNumber = 1;
          final messages = <String>[];

          while (true) {
            final diagStatus = _sql.SQLGetDiagRecW(
              operationType,
              handle,
              recNumber,
              sqlState.cast(),
              nativeErr,
              msg.cast(),
              bufferLength,
              textLenPtr,
            );

            if (diagStatus == SQL_NO_DATA) break;
            if (diagStatus == SQL_SUCCESS || diagStatus == SQL_SUCCESS_WITH_INFO) {
              // textLenPtr contains number of WCHAR chars (usually)
              final dartMessage = msg.toDartString(length: textLenPtr.value);
              final dartState = sqlState.toDartString();
              messages.add('[$dartState] ${dartMessage.trim()} (err=${nativeErr.value})');
            } else {
              break;
            }
            recNumber++;
          }

          if (messages.isNotEmpty) {
            onException.message = messages.join(' | ');
          } else {
            onException.message = 'ODBC error (no diagnostics)';
          }
        } finally {
          calloc.free(sqlState);
          calloc.free(nativeErr);
          calloc.free(msg);
          calloc.free(textLenPtr);
        }
      }

      throw onException;
    }
  }

  List<Map<String, dynamic>> _getResult(
    SQLHSTMT hStmt,
    Map<String, ColumnType> columnConfig,
    List<String>? columnTypes,
  ) {
    final columnCountPtr = calloc<SQLSMALLINT>();
    try {
      tryOdbc(_sql.SQLNumResultCols(hStmt, columnCountPtr), handle: hStmt, onException: FetchException());
      final int columnCount = columnCountPtr.value;
      final columnNames = <String>[];

      if (columnTypes == null) columnTypes = [];
      columnTypes.clear();

      for (var i = 1; i <= columnCount; i++) {
        final nameLenPtr = calloc<SQLSMALLINT>();
        final nameBufChars = 512;
        final nameBuf = calloc<Uint16>(nameBufChars);
        final dataTypePtr = calloc<SQLSMALLINT>();

        try {
          tryOdbc(
            _sql.SQLDescribeColW(
              hStmt,
              i,
              nameBuf.cast(),
              nameBufChars,
              nameLenPtr,
              dataTypePtr,
              nullptr,
              nullptr,
              nullptr,
            ),
            handle: hStmt,
            onException: FetchException(),
          );

          final nameCharCount = nameLenPtr.value;
          final actual = nameBuf.asTypedList(nameCharCount > 0 ? nameCharCount : nameBufChars).where((c) => c != 0).toList();
          columnNames.add(String.fromCharCodes(actual));

          // Map SQL type -> C type string
          final sqlType = dataTypePtr.value;
          String cTypeStr;
          switch (sqlType) {
            case SQL_CHAR:
            case SQL_VARCHAR:
            case SQL_LONGVARCHAR:
              cTypeStr = "SQL_C_CHAR";
              break;
            case SQL_WCHAR:
            case SQL_WVARCHAR:
            case SQL_WLONGVARCHAR:
              cTypeStr = "SQL_C_WCHAR";
              break;
            case SQL_BINARY:
            case SQL_VARBINARY:
            case SQL_LONGVARBINARY:
              cTypeStr = "SQL_C_BINARY";
              break;
            case SQL_INTEGER:
              cTypeStr = "SQL_C_LONG";
              break;
            case SQL_BIGINT:
              cTypeStr = "SQL_C_SBIGINT";
              break;
            case SQL_FLOAT:
              cTypeStr = "SQL_C_FLOAT";
              break;
            case SQL_DOUBLE:
            case SQL_REAL:
              cTypeStr = "SQL_C_DOUBLE";
              break;
            case SQL_TYPE_DATE:
              cTypeStr = "SQL_C_DATE";
              break;
            case SQL_TYPE_TIME:
              cTypeStr = "SQL_C_TIME";
              break;
            case SQL_TYPE_TIMESTAMP:
              cTypeStr = "SQL_C_TIMESTAMP";
              break;
            default:
              cTypeStr = "SQL_C_WCHAR";
              break;
          }
          columnTypes.add(cTypeStr);
        } finally {
          calloc.free(nameBuf);
          calloc.free(nameLenPtr);
          calloc.free(dataTypePtr);
        }
      }

      final rows = <Map<String, dynamic>>[];

      while (true) {
        final fetchRc = _sql.SQLFetch(hStmt);
        if (fetchRc == SQL_NO_DATA) break;
        if (!(fetchRc == SQL_SUCCESS || fetchRc == SQL_SUCCESS_WITH_INFO)) {
          tryOdbc(fetchRc, handle: hStmt, onException: FetchException());
        }

        final row = <String, dynamic>{};

        for (var colIndex = 1; colIndex <= columnCount; colIndex++) {
          final colName = columnNames[colIndex - 1];
          final colType = columnConfig[colName];

          final valueLenPtr = calloc<SQLLEN>();
          // default chunk bytes (512 wide chars -> 1024 bytes)
          final bool isBinary = colType != null && colType.isBinary();
          final int chunkBytes = isBinary ? (colType?.size ?? 1024) : (512 * sizeOf<Uint16>());

          Pointer chunkBuf;
          int bufElements;
          if (isBinary) {
            bufElements = chunkBytes; // bytes
            chunkBuf = calloc<Uint8>(bufElements);
          } else {
            bufElements = chunkBytes ~/ sizeOf<Uint16>();
            chunkBuf = calloc<Uint16>(bufElements);
          }

          final List<int> accumulator = <int>[];
          int rc = SQL_SUCCESS;
          bool sawNull = false;

          try {
            do {
              rc = _sql.SQLGetData(
                hStmt,
                colIndex,
                isBinary ? SQL_C_BINARY : SQL_C_WCHAR,
                chunkBuf.cast(),
                chunkBytes,
                valueLenPtr,
              );

              final int lenOrInd = valueLenPtr.value;

              if (lenOrInd == SQL_NULL_DATA) {
                sawNull = true;
                break;
              }

              if (lenOrInd == SQL_NO_TOTAL) {
                // driver didn't tell total: use actual bytes read in chunk
                if (isBinary) {
                  final part = chunkBuf.cast<Uint8>().asTypedList(bufElements);
                  accumulator.addAll(part);
                } else {
                  // exclude trailing NUL if present
                  final part = chunkBuf.cast<Uint16>().asTypedList(bufElements);
                  final used = part.takeWhile((v) => v != 0).toList();
                  accumulator.addAll(used);
                }
              } else if (lenOrInd > 0) {
                if (isBinary) {
                  final take = lenOrInd < bufElements ? lenOrInd : bufElements;
                  if (take > 0) {
                    final part = chunkBuf.cast<Uint8>().asTypedList(bufElements).sublist(0, take);
                    accumulator.addAll(part);
                  }
                } else {
                  final reportedChars = (lenOrInd / sizeOf<Uint16>()).toInt();
                  final maxChars = bufElements > 0 ? bufElements - 1 : 0;
                  final take = reportedChars < maxChars ? reportedChars : maxChars;
                  if (take > 0) {
                    final part = chunkBuf.cast<Uint16>().asTypedList(bufElements).sublist(0, take);
                    accumulator.addAll(part);
                  }
                }
              }
            } while (rc == SQL_SUCCESS_WITH_INFO);

            if (!(rc == SQL_SUCCESS || rc == SQL_NO_DATA || rc == SQL_SUCCESS_WITH_INFO)) {
              tryOdbc(rc, handle: hStmt, onException: FetchException());
            }

            if (sawNull) {
              row[colName] = null;
            } else if (isBinary) {
              row[colName] = Uint8List.fromList(accumulator);
            } else {
              row[colName] = String.fromCharCodes(accumulator);
            }
          } finally {
            calloc.free(chunkBuf);
            calloc.free(valueLenPtr);
          }
        } // per-column
        rows.add(row);
      } // fetch loop

      return rows;
    } finally {
      calloc.free(columnCountPtr);
    }
  }
}
