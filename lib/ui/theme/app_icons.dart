import 'package:flutter/widgets.dart';

/// Every glyph in the app, by meaning. Widgets never reference an icon
/// font directly: swap the set here and the whole UI follows.
///
/// Glyphs come from the Phosphor icon font (MIT), bundled in
/// assets/fonts/phosphor. Regular by default (closest to SF Symbols at
/// small sizes); Bold for chevrons and tiny marks that would look faint;
/// Fill for selected or emphasised states. To add an icon, look up its
/// codepoint at phosphoricons.com and add a constant plus an entry in [all].
abstract final class AppIcons {
  // Objects
  static const IconData database = IconData(0xe1de, fontFamily: 'PhosphorRegular'); // database
  static const IconData server = IconData(0xe2a0, fontFamily: 'PhosphorRegular'); // hardDrives
  static const IconData table = IconData(0xe476, fontFamily: 'PhosphorRegular'); // table
  static const IconData view = IconData(0xe464, fontFamily: 'PhosphorRegular'); // squaresFour
  static const IconData schema = IconData(0xe466, fontFamily: 'PhosphorRegular'); // stack
  static const IconData tree = IconData(0xe67c, fontFamily: 'PhosphorRegular'); // treeStructure
  static const IconData column = IconData(0xe546, fontFamily: 'PhosphorRegular'); // columns
  static const IconData rows = IconData(0xe5a2, fontFamily: 'PhosphorRegular'); // rows
  static const IconData grid = IconData(0xe296, fontFamily: 'PhosphorRegular'); // gridFour
  static const IconData key = IconData(0xe2d6, fontFamily: 'PhosphorRegular'); // key
  static const IconData link = IconData(0xe2e2, fontFamily: 'PhosphorRegular'); // link
  static const IconData addLink = IconData(0xe2e6, fontFamily: 'PhosphorRegular'); // linkSimple
  static const IconData function = IconData(0xebe4, fontFamily: 'PhosphorRegular'); // function
  static const IconData procedure = IconData(0xe272, fontFamily: 'PhosphorRegular'); // gearSix
  static const IconData erDiagram = IconData(0xeb58, fontFamily: 'PhosphorRegular'); // graph
  static const IconData join = IconData(0xe2d2, fontFamily: 'PhosphorRegular'); // intersect
  static const IconData json = IconData(0xe860, fontFamily: 'PhosphorRegular'); // bracketsCurly
  static const IconData number = IconData(0xe2a2, fontFamily: 'PhosphorRegular'); // hash
  static const IconData text = IconData(0xe48a, fontFamily: 'PhosphorRegular'); // textT
  static const IconData shortText = IconData(0xe484, fontFamily: 'PhosphorRegular'); // textAlignLeft
  static const IconData category = IconData(0xec5e, fontFamily: 'PhosphorRegular'); // shapes
  static const IconData hub = IconData(0xe408, fontFamily: 'PhosphorRegular'); // shareNetwork
  static const IconData extension = IconData(0xe596, fontFamily: 'PhosphorRegular'); // puzzlePiece
  static const IconData archive = IconData(0xe00c, fontFamily: 'PhosphorRegular'); // archive
  static const IconData memory = IconData(0xe610, fontFamily: 'PhosphorRegular'); // cpu
  static const IconData leaf = IconData(0xe2da, fontFamily: 'PhosphorRegular'); // leaf
  static const IconData snowflake = IconData(0xe5aa, fontFamily: 'PhosphorRegular'); // snowflake
  static const IconData fire = IconData(0xe242, fontFamily: 'PhosphorRegular'); // fire
  static const IconData bolt = IconData(0xe2de, fontFamily: 'PhosphorRegular'); // lightning
  static const IconData blur = IconData(0xe1fc, fontFamily: 'PhosphorRegular'); // dotsNine
  static const IconData palette = IconData(0xe6c8, fontFamily: 'PhosphorRegular'); // palette
  static const IconData image = IconData(0xe2ca, fontFamily: 'PhosphorRegular'); // image
  static const IconData calendar = IconData(0xe10a, fontFamily: 'PhosphorRegular'); // calendarBlank
  static const IconData timer = IconData(0xe492, fontFamily: 'PhosphorRegular'); // timer
  static const IconData hourglass = IconData(0xe2b2, fontFamily: 'PhosphorRegular'); // hourglass
  static const IconData random = IconData(0xe1ee, fontFamily: 'PhosphorRegular'); // diceFive

  // Tools and features
  static const IconData code = IconData(0xe1bc, fontFamily: 'PhosphorRegular'); // code
  static const IconData terminal = IconData(0xeae8, fontFamily: 'PhosphorRegular'); // terminalWindow
  static const IconData debug = IconData(0xe5f4, fontFamily: 'PhosphorRegular'); // bug
  static const IconData performance = IconData(0xe628, fontFamily: 'PhosphorRegular'); // gauge
  static const IconData insights = IconData(0xe156, fontFamily: 'PhosphorRegular'); // chartLineUp
  static const IconData git = IconData(0xe278, fontFamily: 'PhosphorRegular'); // gitBranch
  static const IconData diff = IconData(0xe27c, fontFamily: 'PhosphorRegular'); // gitDiff
  static const IconData compare = IconData(0xe0a0, fontFamily: 'PhosphorRegular'); // arrowsLeftRight
  static const IconData split = IconData(0xed3c, fontFamily: 'PhosphorRegular'); // arrowsSplit
  static const IconData ai = IconData(0xe6a2, fontFamily: 'PhosphorRegular'); // sparkle
  static const IconData compose = IconData(0xe16e, fontFamily: 'PhosphorRegular'); // chatCircleText
  static const IconData format = IconData(0xe6b6, fontFamily: 'PhosphorRegular'); // magicWand
  static const IconData fix = IconData(0xe0b2, fontFamily: 'PhosphorRegular'); // bandaids
  static const IconData tune = IconData(0xe434, fontFamily: 'PhosphorRegular'); // slidersHorizontal
  static const IconData settings = IconData(0xe270, fontFamily: 'PhosphorRegular'); // gear
  static const IconData palettePanel = IconData(0xe874, fontFamily: 'PhosphorRegular'); // squareSplitVertical
  static const IconData sidebar = IconData(0xec24, fontFamily: 'PhosphorRegular'); // sidebarSimple
  static const IconData mosaic = IconData(0xe464, fontFamily: 'PhosphorRegular'); // squaresFour

  // Files
  static const IconData file = IconData(0xe230, fontFamily: 'PhosphorRegular'); // file
  static const IconData document = IconData(0xe23a, fontFamily: 'PhosphorRegular'); // fileText
  static const IconData article = IconData(0xe0a8, fontFamily: 'PhosphorRegular'); // article
  static const IconData notes = IconData(0xe63e, fontFamily: 'PhosphorRegular'); // notepad
  static const IconData script = IconData(0xe34c, fontFamily: 'PhosphorRegular'); // notePencil
  static const IconData newScript = IconData(0xe236, fontFamily: 'PhosphorRegular'); // filePlus
  static const IconData scriptFromSelection = IconData(0xedf6, fontFamily: 'PhosphorRegular'); // stackPlus
  static const IconData folder = IconData(0xe24a, fontFamily: 'PhosphorRegular'); // folder
  static const IconData folderOpen = IconData(0xe256, fontFamily: 'PhosphorRegular'); // folderOpen
  static const IconData newFolder = IconData(0xe258, fontFamily: 'PhosphorRegular'); // folderPlus
  static const IconData zip = IconData(0xe958, fontFamily: 'PhosphorRegular'); // fileZip
  static const IconData save = IconData(0xe248, fontFamily: 'PhosphorRegular'); // floppyDisk
  static const IconData download = IconData(0xe20c, fontFamily: 'PhosphorRegular'); // downloadSimple
  static const IconData upload = IconData(0xe4c0, fontFamily: 'PhosphorRegular'); // uploadSimple
  static const IconData share = IconData(0xeaf0, fontFamily: 'PhosphorRegular'); // export
  static const IconData insert = IconData(0xe5dc, fontFamily: 'PhosphorRegular'); // arrowSquareIn
  static const IconData openExternal = IconData(0xe5de, fontFamily: 'PhosphorRegular'); // arrowSquareOut
  static const IconData copy = IconData(0xe1ca, fontFamily: 'PhosphorRegular'); // copy
  static const IconData duplicate = IconData(0xe1cc, fontFamily: 'PhosphorRegular'); // copySimple
  static const IconData paste = IconData(0xe196, fontFamily: 'PhosphorRegular'); // clipboard
  static const IconData empty = IconData(0xe4aa, fontFamily: 'PhosphorRegular'); // tray

  // Cloud
  static const IconData cloud = IconData(0xe1aa, fontFamily: 'PhosphorRegular'); // cloud
  static const IconData cloudUpload = IconData(0xe1ae, fontFamily: 'PhosphorRegular'); // cloudArrowUp
  static const IconData cloudOff = IconData(0xe1b6, fontFamily: 'PhosphorRegular'); // cloudSlash
  static const IconData cloudSync = IconData(0xe1b0, fontFamily: 'PhosphorRegular'); // cloudCheck

  // Actions
  static const IconData add = IconData(0xe3d4, fontFamily: 'PhosphorRegular'); // plus
  static const IconData addBox = IconData(0xed4a, fontFamily: 'PhosphorRegular'); // plusSquare
  static const IconData addList = IconData(0xe2f8, fontFamily: 'PhosphorRegular'); // listPlus
  static const IconData remove = IconData(0xe32a, fontFamily: 'PhosphorRegular'); // minus
  static const IconData removeCircle = IconData(0xe32c, fontFamily: 'PhosphorRegular'); // minusCircle
  static const IconData close = IconData(0xe4f6, fontFamily: 'PhosphorRegular'); // x
  static const IconData cancel = IconData(0xe4f8, fontFamily: 'PhosphorRegular'); // xCircle
  static const IconData clearFill = IconData(0xe4f8, fontFamily: 'PhosphorFill'); // xCircle
  static const IconData delete = IconData(0xe4a6, fontFamily: 'PhosphorRegular'); // trash
  static const IconData clearAll = IconData(0xec54, fontFamily: 'PhosphorRegular'); // broom
  static const IconData edit = IconData(0xe3b4, fontFamily: 'PhosphorRegular'); // pencilSimple
  static const IconData rename = IconData(0xe3b2, fontFamily: 'PhosphorRegular'); // pencilLine
  static const IconData search = IconData(0xe30c, fontFamily: 'PhosphorRegular'); // magnifyingGlass
  static const IconData zoomIn = IconData(0xe310, fontFamily: 'PhosphorRegular'); // magnifyingGlassPlus
  static const IconData zoomOut = IconData(0xe30e, fontFamily: 'PhosphorRegular'); // magnifyingGlassMinus
  static const IconData fitScreen = IconData(0xe1d0, fontFamily: 'PhosphorRegular'); // cornersOut
  static const IconData expand = IconData(0xe0a2, fontFamily: 'PhosphorRegular'); // arrowsOut
  static const IconData widthNormal = IconData(0xe534, fontFamily: 'PhosphorRegular'); // arrowsOutLineHorizontal
  static const IconData filter = IconData(0xe266, fontFamily: 'PhosphorRegular'); // funnel
  static const IconData filterOff = IconData(0xe26c, fontFamily: 'PhosphorRegular'); // funnelX
  static const IconData sort = IconData(0xe444, fontFamily: 'PhosphorRegular'); // sortAscending
  static const IconData selectAll = IconData(0xe746, fontFamily: 'PhosphorRegular'); // selectionAll
  static const IconData deselectAll = IconData(0xe69e, fontFamily: 'PhosphorRegular'); // selectionSlash
  static const IconData doneAll = IconData(0xe53a, fontFamily: 'PhosphorRegular'); // checks
  static const IconData refresh = IconData(0xe036, fontFamily: 'PhosphorRegular'); // arrowClockwise
  static const IconData sync = IconData(0xe094, fontFamily: 'PhosphorRegular'); // arrowsClockwise
  static const IconData undo = IconData(0xe08a, fontFamily: 'PhosphorRegular'); // arrowUUpLeft
  static const IconData redo = IconData(0xe08c, fontFamily: 'PhosphorRegular'); // arrowUUpRight
  static const IconData replay = IconData(0xe038, fontFamily: 'PhosphorRegular'); // arrowCounterClockwise
  static const IconData history = IconData(0xe1a0, fontFamily: 'PhosphorRegular'); // clockCounterClockwise
  static const IconData run = IconData(0xe3d0, fontFamily: 'PhosphorFill'); // play
  static const IconData runOutline = IconData(0xe3d0, fontFamily: 'PhosphorRegular'); // play
  static const IconData runCircle = IconData(0xe3d2, fontFamily: 'PhosphorRegular'); // playCircle
  static const IconData pause = IconData(0xe39e, fontFamily: 'PhosphorFill'); // pause
  static const IconData stop = IconData(0xe46c, fontFamily: 'PhosphorFill'); // stop
  static const IconData stopCircle = IconData(0xe46e, fontFamily: 'PhosphorRegular'); // stopCircle
  static const IconData stepOver = IconData(0xe6a6, fontFamily: 'PhosphorRegular'); // fastForward
  static const IconData power = IconData(0xe3da, fontFamily: 'PhosphorRegular'); // power
  static const IconData connect = IconData(0xeb5a, fontFamily: 'PhosphorRegular'); // plugsConnected
  static const IconData disconnect = IconData(0xeb56, fontFamily: 'PhosphorRegular'); // plugs
  static const IconData plug = IconData(0xe946, fontFamily: 'PhosphorRegular'); // plug
  static const IconData lock = IconData(0xe2fa, fontFamily: 'PhosphorRegular'); // lock
  static const IconData lockOpen = IconData(0xe306, fontFamily: 'PhosphorRegular'); // lockOpen
  static const IconData security = IconData(0xe40a, fontFamily: 'PhosphorRegular'); // shield
  static const IconData user = IconData(0xe4c2, fontFamily: 'PhosphorRegular'); // user
  static const IconData role = IconData(0xe4d6, fontFamily: 'PhosphorRegular'); // users
  static const IconData group = IconData(0xe68e, fontFamily: 'PhosphorRegular'); // usersThree
  static const IconData login = IconData(0xe6f6, fontFamily: 'PhosphorRegular'); // identificationBadge
  static const IconData eye = IconData(0xe220, fontFamily: 'PhosphorRegular'); // eye
  static const IconData eyeOff = IconData(0xe224, fontFamily: 'PhosphorRegular'); // eyeSlash
  static const IconData block = IconData(0xe3de, fontFamily: 'PhosphorRegular'); // prohibit
  static const IconData swapVertical = IconData(0xe098, fontFamily: 'PhosphorRegular'); // arrowsDownUp
  static const IconData swapHorizontal = IconData(0xe0a0, fontFamily: 'PhosphorRegular'); // arrowsLeftRight
  static const IconData alignLeft = IconData(0xe50e, fontFamily: 'PhosphorRegular'); // alignLeft
  static const IconData more = IconData(0xe1fe, fontFamily: 'PhosphorBold'); // dotsThree

  // Charts
  static const IconData chart = IconData(0xe150, fontFamily: 'PhosphorRegular'); // chartBar
  static const IconData barChart = IconData(0xe150, fontFamily: 'PhosphorRegular'); // chartBar
  static const IconData lineChart = IconData(0xe154, fontFamily: 'PhosphorRegular'); // chartLine
  static const IconData areaChart = IconData(0xe156, fontFamily: 'PhosphorRegular'); // chartLineUp
  static const IconData pieChart = IconData(0xe158, fontFamily: 'PhosphorRegular'); // chartPie
  static const IconData donutChart = IconData(0xeaa6, fontFamily: 'PhosphorRegular'); // chartDonut
  static const IconData scatterChart = IconData(0xeaac, fontFamily: 'PhosphorRegular'); // chartScatter

  // Navigation and disclosure
  static const IconData chevronRight = IconData(0xe13a, fontFamily: 'PhosphorBold'); // caretRight
  static const IconData chevronLeft = IconData(0xe138, fontFamily: 'PhosphorBold'); // caretLeft
  static const IconData chevronDown = IconData(0xe136, fontFamily: 'PhosphorBold'); // caretDown
  static const IconData chevronUp = IconData(0xe13c, fontFamily: 'PhosphorBold'); // caretUp
  static const IconData upDown = IconData(0xe140, fontFamily: 'PhosphorBold'); // caretUpDown
  static const IconData expandAll = IconData(0xe126, fontFamily: 'PhosphorRegular'); // caretDoubleDown
  static const IconData collapseAll = IconData(0xe532, fontFamily: 'PhosphorRegular'); // arrowsInLineVertical
  static const IconData firstPage = IconData(0xe132, fontFamily: 'PhosphorRegular'); // caretLineLeft
  static const IconData lastPage = IconData(0xe130, fontFamily: 'PhosphorRegular'); // caretLineRight
  static const IconData arrowUp = IconData(0xe08e, fontFamily: 'PhosphorRegular'); // arrowUp
  static const IconData arrowDown = IconData(0xe03e, fontFamily: 'PhosphorRegular'); // arrowDown
  static const IconData arrowLeft = IconData(0xe058, fontFamily: 'PhosphorRegular'); // arrowLeft
  static const IconData incoming = IconData(0xe040, fontFamily: 'PhosphorRegular'); // arrowDownLeft
  static const IconData subdirectory = IconData(0xe046, fontFamily: 'PhosphorRegular'); // arrowElbowDownRight

  // Status
  static const IconData check = IconData(0xe182, fontFamily: 'PhosphorBold'); // check
  static const IconData checkCircle = IconData(0xe184, fontFamily: 'PhosphorRegular'); // checkCircle
  static const IconData checkCircleFill = IconData(0xe184, fontFamily: 'PhosphorFill'); // checkCircle
  static const IconData info = IconData(0xe2ce, fontFamily: 'PhosphorRegular'); // info
  static const IconData help = IconData(0xe3e8, fontFamily: 'PhosphorRegular'); // question
  static const IconData warning = IconData(0xe4e0, fontFamily: 'PhosphorRegular'); // warning
  static const IconData warningFill = IconData(0xe4e0, fontFamily: 'PhosphorFill'); // warning
  static const IconData error = IconData(0xe4e2, fontFamily: 'PhosphorRegular'); // warningCircle
  static const IconData errorFill = IconData(0xe4e2, fontFamily: 'PhosphorFill'); // warningCircle
  static const IconData dot = IconData(0xe18a, fontFamily: 'PhosphorFill'); // circle

  // Selected navigator tabs (Fill of the sidebar glyphs)
  static const IconData databaseFill = IconData(0xe1de, fontFamily: 'PhosphorFill'); // database
  static const IconData documentFill = IconData(0xe23a, fontFamily: 'PhosphorFill'); // fileText
  static const IconData cloudFill = IconData(0xe1aa, fontFamily: 'PhosphorFill'); // cloud
  static const IconData gitFill = IconData(0xe278, fontFamily: 'PhosphorFill'); // gitBranch

  /// Every icon by name (control gallery).
  static const Map<String, IconData> all = {
    'database': database,
    'server': server,
    'table': table,
    'view': view,
    'schema': schema,
    'tree': tree,
    'column': column,
    'rows': rows,
    'grid': grid,
    'key': key,
    'link': link,
    'addLink': addLink,
    'function': function,
    'procedure': procedure,
    'erDiagram': erDiagram,
    'join': join,
    'json': json,
    'number': number,
    'text': text,
    'shortText': shortText,
    'category': category,
    'hub': hub,
    'extension': extension,
    'archive': archive,
    'memory': memory,
    'leaf': leaf,
    'snowflake': snowflake,
    'fire': fire,
    'bolt': bolt,
    'blur': blur,
    'palette': palette,
    'image': image,
    'calendar': calendar,
    'timer': timer,
    'hourglass': hourglass,
    'random': random,
    'code': code,
    'terminal': terminal,
    'debug': debug,
    'performance': performance,
    'insights': insights,
    'git': git,
    'diff': diff,
    'compare': compare,
    'split': split,
    'ai': ai,
    'compose': compose,
    'format': format,
    'fix': fix,
    'tune': tune,
    'settings': settings,
    'palettePanel': palettePanel,
    'sidebar': sidebar,
    'mosaic': mosaic,
    'file': file,
    'document': document,
    'article': article,
    'notes': notes,
    'script': script,
    'newScript': newScript,
    'scriptFromSelection': scriptFromSelection,
    'folder': folder,
    'folderOpen': folderOpen,
    'newFolder': newFolder,
    'zip': zip,
    'save': save,
    'download': download,
    'upload': upload,
    'share': share,
    'insert': insert,
    'openExternal': openExternal,
    'copy': copy,
    'duplicate': duplicate,
    'paste': paste,
    'empty': empty,
    'cloud': cloud,
    'cloudUpload': cloudUpload,
    'cloudOff': cloudOff,
    'cloudSync': cloudSync,
    'add': add,
    'addBox': addBox,
    'addList': addList,
    'remove': remove,
    'removeCircle': removeCircle,
    'close': close,
    'cancel': cancel,
    'clearFill': clearFill,
    'delete': delete,
    'clearAll': clearAll,
    'edit': edit,
    'rename': rename,
    'search': search,
    'zoomIn': zoomIn,
    'zoomOut': zoomOut,
    'fitScreen': fitScreen,
    'expand': expand,
    'widthNormal': widthNormal,
    'filter': filter,
    'filterOff': filterOff,
    'sort': sort,
    'selectAll': selectAll,
    'deselectAll': deselectAll,
    'doneAll': doneAll,
    'refresh': refresh,
    'sync': sync,
    'undo': undo,
    'redo': redo,
    'replay': replay,
    'history': history,
    'run': run,
    'runOutline': runOutline,
    'runCircle': runCircle,
    'pause': pause,
    'stop': stop,
    'stopCircle': stopCircle,
    'stepOver': stepOver,
    'power': power,
    'connect': connect,
    'disconnect': disconnect,
    'plug': plug,
    'lock': lock,
    'lockOpen': lockOpen,
    'security': security,
    'user': user,
    'role': role,
    'group': group,
    'login': login,
    'eye': eye,
    'eyeOff': eyeOff,
    'block': block,
    'swapVertical': swapVertical,
    'swapHorizontal': swapHorizontal,
    'alignLeft': alignLeft,
    'more': more,
    'chart': chart,
    'barChart': barChart,
    'lineChart': lineChart,
    'areaChart': areaChart,
    'pieChart': pieChart,
    'donutChart': donutChart,
    'scatterChart': scatterChart,
    'chevronRight': chevronRight,
    'chevronLeft': chevronLeft,
    'chevronDown': chevronDown,
    'chevronUp': chevronUp,
    'upDown': upDown,
    'expandAll': expandAll,
    'collapseAll': collapseAll,
    'firstPage': firstPage,
    'lastPage': lastPage,
    'arrowUp': arrowUp,
    'arrowDown': arrowDown,
    'arrowLeft': arrowLeft,
    'incoming': incoming,
    'subdirectory': subdirectory,
    'check': check,
    'checkCircle': checkCircle,
    'checkCircleFill': checkCircleFill,
    'info': info,
    'help': help,
    'warning': warning,
    'error': error,
    'errorFill': errorFill,
    'warningFill': warningFill,
    'dot': dot,
    'databaseFill': databaseFill,
    'documentFill': documentFill,
    'cloudFill': cloudFill,
    'gitFill': gitFill,
  };
}
