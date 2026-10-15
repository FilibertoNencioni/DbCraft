// AI assistant (Claude): explain queries and objects, fix failed
// statements, generate SQL from natural language, chat about a database.
export 'ai_chat.dart' show AiChatTab;
export 'ai_dialogs.dart'
    show showAiExplainQuery, showAiExplainObject, showAiExplainProcedure, showAiFixQuery, showAiGenerateSql;
export 'ai_service.dart' show aiAvailable;
export 'ai_settings.dart' show aiSettingsSection, ensureAiReady;
