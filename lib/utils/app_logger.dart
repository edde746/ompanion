import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

final appLogger = Logger(printer: SimplePrinter(printTime: true), level: kDebugMode ? Level.debug : Level.info);
