import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../core/download_manager.dart';
import '../core/models.dart';
import '../core/remote_config.dart';
import '../theme/app_theme.dart';
import 'app_popup_dialog.dart';
import 'downloads_page.dart';
import 'pwd_query_page.dart';

/// 主界面：粘贴分享链接 → 浏览目录勾选文件 → 解析直链并下载。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.client,
    required this.config,
    required this.onReloadConfig,
    required this.onToggleTheme,
  });

  final ParseApiClient client;
  final ParseConfig config;
  final Future<ParseConfig> Function() onReloadConfig;
  final VoidCallback onToggleTheme;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _linkController = TextEditingController();
  final TextEditingController _pwdController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final FocusNode _linkFocus = FocusNode();

  final DownloadManager _downloads = DownloadManager.instance;

  late ParseConfig _config;
  LimitInfo? _limit;

  bool _running = false;
  String? _statusText;
  String? _errorText;

  ShareLink? _share;
  FileListData? _listing;

  /// 当前目录路径（`/` 为分享根目录）。
  String _dir = '/';

  final Set<int> _selected = <int>{};

  /// 已解析出的直链（`name` 便于展示与命名落盘文件，`ua` 供引擎透传）。
  final List<({String url, String name, String ua})> _results =
      <({String url, String name, String ua})>[];

  VcodeInfo _vcode = const VcodeInfo();

  /// 远程公告文案，拉取失败时回落到 [kFallbackAnnounce]。
  String _announce = kFallbackAnnounce;

  /// 后台下发的解析密码，用户无需手动填写。
  String _parsePassword = '';

  /// 后台下发的密码查询站地址（空则用内置默认值）。
  String _pwdSiteUrl = kPwdSiteUrl;

  /// 后台下发的密码查询站第一层密码（空则用内置默认值）。
  String _pwdFirstPassword = kFirstLayerPassword;

  /// 启动弹窗是否已展示过（每次启动只弹一次）。
  bool _popupShown = false;

  /// 后台下发的首页启动弹窗（加群公告），仅首页使用。
  AppPopup _popup = const AppPopup();

  /// 「获取解析密码」页专用弹窗，与首页加群弹窗相互独立。
  AppPopup _pwdPopup = kFallbackPwdPopup;

  /// 远程配置是否已尝试拉取过（用于避免启动瞬间误报「未获取密码」）。
  bool _remoteLoaded = false;

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _tokenController.text = widget.client.token;
    unawaitedRefreshLimit();
    _loadRemoteConfig();
  }

  /// 拉取自有后端配置：公告、解析密码、密码查询站配置与启动弹窗。
  ///
  /// 失败静默（公告保留兜底文案、解析密码保持当前值）。
  Future<void> _loadRemoteConfig() async {
    final remote = await RemoteConfigService().load();
    if (!mounted) return;
    setState(() {
      _remoteLoaded = true;
      if (remote == null) return;
      if (remote.announcement.isNotEmpty) _announce = remote.announcement;
      if (remote.parsePassword.isNotEmpty) {
        _parsePassword = remote.parsePassword;
      }
      if (remote.pwdSiteUrl.isNotEmpty) _pwdSiteUrl = remote.pwdSiteUrl;
      if (remote.pwdFirstPassword.isNotEmpty) {
        _pwdFirstPassword = remote.pwdFirstPassword;
      }
      _popup = remote.popup;
      _pwdPopup = remote.pwdPopup;
    });
    if (remote != null) _maybeShowPopup();
  }

  /// 确保解析密码已就绪：为空时强制刷新远程配置再取一次。
  ///
  /// 返回 `true` 表示 [ _parsePassword ] 非空，可安全发起解析请求。
  Future<bool> _ensureParsePassword() async {
    if (_parsePassword.isNotEmpty) return true;
    try {
      final remote = await RemoteConfigService().load(useCache: false);
      if (remote != null && remote.parsePassword.isNotEmpty) {
        if (mounted) {
          setState(() => _parsePassword = remote.parsePassword);
        } else {
          _parsePassword = remote.parsePassword;
        }
      }
    } catch (_) {
      // 拉取失败时交由调用方统一提示。
    }
    return _parsePassword.isNotEmpty;
  }

  /// 打开密码查询页：用户过完人机验证后，把抓到的解析密码回填到 [_parsePassword]。
  ///
  /// 站点地址与第一层密码由自有后端远程下发，拉取失败时用内置默认值。
  /// WebView 仅在 Android / iOS / macOS 可用，其它平台提示不支持。
  Future<void> _openPwdQuery() async {
    if (!PwdQueryPage.isSupported) {
      _toast('当前平台暂不支持内置密码查询，请手动填写解析密码');
      return;
    }
    // 打开前强制刷新一次远程配置，确保站点地址、第一层密码与公告是最新的。
    try {
      final remote = await RemoteConfigService().load(useCache: false);
      if (remote != null) {
        if (remote.pwdSiteUrl.isNotEmpty) _pwdSiteUrl = remote.pwdSiteUrl;
        if (remote.pwdFirstPassword.isNotEmpty) {
          _pwdFirstPassword = remote.pwdFirstPassword;
        }
        _popup = remote.popup;
        _pwdPopup = remote.pwdPopup;
      }
    } catch (_) {
      // 拉取失败时沿用当前值（首次为内置默认值）。
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<PwdQueryResult>(
      MaterialPageRoute<PwdQueryResult>(
        builder: (_) => PwdQueryPage(
          siteUrl: _pwdSiteUrl,
          firstPassword: _pwdFirstPassword,
          popup: _pwdPopup,
          // 抓到密码即刻生效，用户直接返回也不会丢。
          onPasswordCaptured: _applyCapturedPassword,
        ),
      ),
    );
    // 页面返回时再兜底一次：以返回值（用户点「使用该密码」）为准。
    if (result != null && result.pwd.isNotEmpty) {
      final changed = _applyCapturedPassword(result);
      if (changed) _toast('已获取解析密码：${result.pwd}');
    }
  }

  /// 应用抓到的解析密码（页面内首次拿到、以及返回时都会走这里）。
  ///
  /// 返回是否发生了变更；本方法不弹提示，由调用方决定（页面在前台时提示会被遮住）。
  bool _applyCapturedPassword(PwdQueryResult result) {
    if (!mounted || result.pwd.isEmpty) return false;
    if (_parsePassword == result.pwd) return false;
    setState(() => _parsePassword = result.pwd);
    return true;
  }

  /// 展示后台下发的首页启动弹窗（每次启动只弹一次）。
  Future<void> _maybeShowPopup() async {
    if (_popupShown || !_popup.isVisible) return;
    _popupShown = true;
    await showAppPopupDialog(context, popup: _popup);
  }

  @override
  void dispose() {
    _linkController.dispose();
    _pwdController.dispose();
    _tokenController.dispose();
    _linkFocus.dispose();
    super.dispose();
  }

  /// 刷新剩余配额（失败静默，不打断主流程）。
  Future<void> unawaitedRefreshLimit() async {
    try {
      final limit = await widget.client.getLimit();
      if (mounted) setState(() => _limit = limit);
    } catch (_) {
      // 配额仅作展示，失败可忽略。
    }
  }

  Future<void> _reloadConfig() async {
    setState(() {
      _statusText = '正在刷新接口配置…';
      _errorText = null;
    });
    try {
      final fresh = await widget.onReloadConfig();
      if (!mounted) return;
      setState(() {
        _config = fresh;
        _statusText = '接口配置已更新';
      });
    } catch (error) {
      if (mounted) setState(() => _errorText = '刷新配置失败：$error');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 保存 token 并用新 token 重新拉取配置与配额。
  Future<void> _applyToken() async {
    final text = _tokenController.text.trim();
    await widget.client.setToken(text);
    if (!mounted) return;
    setState(() => _tokenController.text = widget.client.token);
    await _reloadConfig();
    await unawaitedRefreshLimit();
  }

  /// 拉取（或刷新）当前目录的文件列表。
  Future<void> _loadFileList({String? dir}) async {
    final share = _share;
    if (share == null) return;

    setState(() {
      _running = true;
      _errorText = null;
      _statusText = '正在读取文件列表…';
      _results.clear();
      _selected.clear();
      _vcode = const VcodeInfo();
    });

    try {
      final data = await widget.client.getFileList(
        url: share.url,
        surl: share.surl,
        pwd: share.pwd,
        dir: dir ?? _dir,
        parsePassword: _parsePassword,
      );
      if (!mounted) return;
      setState(() {
        _dir = dir ?? _dir;
        _listing = data;
        _statusText = '共 ${data.list.length} 个条目，勾选后点击「解析直链」';
      });
    } on ParseException catch (error) {
      if (mounted) {
        setState(() {
          _errorText = error.message;
          _statusText = null;
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _startList() async {
    final raw = _linkController.text.trim();
    if (raw.isEmpty) {
      setState(() => _errorText = '请先粘贴百度网盘分享链接');
      _linkFocus.requestFocus();
      return;
    }
    _linkFocus.unfocus();

    final share = parseShareLink(raw);
    if (!share.isValid) {
      setState(() => _errorText = '未能识别分享链接，请检查是否包含 /s/ 后的分享 id');
      return;
    }

    // 链接内自带提取码时回填输入框，用户也可手动修改。
    if (_pwdController.text.trim().isEmpty && share.pwd.isNotEmpty) {
      _pwdController.text = share.pwd;
    }
    final pwd = _pwdController.text.trim();
    final normalized = ShareLink(
      url: pwd.isEmpty
          ? 'https://pan.baidu.com/s/${share.surl}'
          : 'https://pan.baidu.com/s/${share.surl}?pwd=$pwd',
      surl: share.surl,
      pwd: pwd,
    );

    if (!await _ensureParsePassword()) {
      if (mounted) {
        setState(() => _errorText = '尚未获取解析密码，请点击右上角钥匙图标或上方「去获取」完成人机验证');
      }
      return;
    }
    if (!mounted) return;

    setState(() {
      _share = normalized;
      _dir = '/';
      _listing = null;
      _results.clear();
      _selected.clear();
    });
    await _loadFileList(dir: '/');
  }

  /// 点击目录进入 / 返回上一层。
  Future<void> _enterItem(FileItem item) async {
    if (!item.isDir) return;
    await _loadFileList(dir: item.path);
  }

  void _toggleSelect(FileItem item, bool? value) {
    if (item.category == -1) return;
    setState(() {
      if (value == true) {
        _selected.add(item.fsId);
      } else {
        _selected.remove(item.fsId);
      }
    });
  }

  /// 解析勾选文件：先按站点规则过滤，再逐个串行请求直链。
  Future<void> _parseSelected() async {
    final listing = _listing;
    final share = _share;
    if (listing == null || share == null) return;

    final chosen =
        listing.list.where((e) => _selected.contains(e.fsId)).toList();
    if (chosen.isEmpty) {
      _toast('请先勾选需要解析的文件');
      return;
    }

    final dirs = chosen.where((e) => e.isDir).toList();
    var files = chosen.where((e) => !e.isDir).toList();
    if (dirs.isNotEmpty) {
      _toast('暂时不支持解析文件夹');
    }

    final minOk = files.where((e) => e.size > _config.minSingleFilesize).toList();
    if (minOk.length != files.length) _toast('文件过小不会被解析');
    final maxOk =
        minOk.where((e) => e.size < _config.maxSingleFilesize).toList();
    if (maxOk.length != minOk.length) _toast('文件过大不会被解析');
    files = maxOk;

    final totalSize = files.fold<int>(0, (sum, e) => sum + e.size);
    if (_config.maxAllFilesize > 0 && totalSize > _config.maxAllFilesize) {
      setState(() => _errorText =
          '单次最多解析 ${DownloadItem.formatBytes(_config.maxAllFilesize)} 的文件');
      return;
    }
    if (_config.maxOnce > 0 && files.length > _config.maxOnce) {
      setState(() => _errorText = '单次最多解析 ${_config.maxOnce} 个文件');
      return;
    }
    if (files.isEmpty) {
      setState(() => _errorText = '满足要求的文件数量为 0');
      return;
    }

    setState(() {
      _running = true;
      _errorText = null;
      _results.clear();
      _vcode = _vcode.copyWith(hitCaptcha: false);
    });

    final collected = <({String url, String name, String ua})>[];
    var lastError = '';
    try {
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        if (mounted) {
          setState(() => _statusText =
              '正在解析第 ${i + 1}/${files.length} 个文件：${file.serverFilename}');
        }
        try {
          final links = await widget.client.getDownloadLinks(
            randsk: listing.randsk,
            uk: listing.uk,
            shareid: listing.shareid,
            fsId: <int>[file.fsId],
            dlink: file.dlink.isEmpty ? const [] : <String>[file.dlink],
            surl: share.surl,
            dir: _dir,
            pwd: share.pwd,
            parsePassword: _parsePassword,
            vcodeStr: _vcode.vcodeStr,
            vcodeInput: _vcode.vcodeInput,
          );
          for (final link in links) {
            collected.add((
              url: link.url,
              name: link.name.isEmpty ? file.serverFilename : link.name,
              ua: link.ua,
            ));
          }
          if (mounted) setState(() => _selected.remove(file.fsId));
        } on ParseException catch (error) {
          lastError = error.message;
          if (error.needCaptcha) {
            await _fetchVcode();
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _results
            ..clear()
            ..addAll(collected);
          _running = false;
          _statusText = collected.isEmpty
              ? null
              : '解析成功，共 ${collected.length} 条直链';
          if (collected.isEmpty && lastError.isNotEmpty) {
            _errorText = lastError;
          }
        });
      }
      await unawaitedRefreshLimit();
    }
  }

  /// 拉取图形验证码（服务端提示需要验证码时触发）。
  Future<void> _fetchVcode() async {
    try {
      final info = await widget.client
          .getVcode(parsePassword: _parsePassword);
      if (!mounted) return;
      setState(() {
        _vcode = info.copyWith(hitCaptcha: true, vcodeInput: '');
      });
      await _showVcodeDialog();
    } catch (_) {
      // 验证码获取失败时保留原始错误提示。
    }
  }

  /// 弹出验证码输入框，确认后回填 [_vcode] 供重试使用。
  Future<void> _showVcodeDialog() async {
    final controller = TextEditingController(text: _vcode.vcodeInput);
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要图形验证码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _buildVcodeImage(),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '验证码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (input == null || input.isEmpty) return;
    setState(() => _vcode = _vcode.copyWith(vcodeInput: input));
    _toast('已填写验证码，请重新点击「解析直链」');
  }

  Widget _buildVcodeImage() {
    final raw = _vcode.vcodeImg;
    if (raw.isEmpty) return const SizedBox(height: 48);
    if (raw.startsWith('data:')) {
      try {
        final bytes = base64Decode(raw.split(',').last);
        return Image.memory(bytes, height: 48);
      } catch (_) {
        return const SizedBox(height: 48);
      }
    }
    final uri = Uri.tryParse(raw);
    final resolved = (uri != null && uri.hasScheme)
        ? raw
        : '${Uri.parse(widget.client.baseUrl).origin}/'
            '${raw.replaceFirst(RegExp(r'^/+'), '')}';
    return Image.network(
      resolved,
      height: 48,
      errorBuilder: (_, _, _) => const SizedBox(height: 48),
    );
  }

  Future<void> _downloadWithEngine(
      String url, String name, String ua) async {
    try {
      final headers = ua.trim().isEmpty
          ? const <String, String>{}
          : <String, String>{'User-Agent': ua.trim()};
      final item = await _downloads.download(url: url, name: name, headers: headers);
      _toast('已添加到下载任务：${item.name}');
    } catch (error) {
      _toast('创建下载任务失败：$error');
    }
  }

  Future<void> _copy(String value, {String message = '已复制到剪贴板'}) async {
    await Clipboard.setData(ClipboardData(text: value));
    _toast(message);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) return;
    setState(() => _linkController.text = text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('百度公益解析'),
        actions: <Widget>[
          IconButton(
            tooltip: '获取解析密码',
            onPressed: _openPwdQuery,
            icon: const Icon(Icons.key_rounded),
          ),
          IconButton(
            tooltip: isDark ? '切换浅色' : '切换深色',
            onPressed: widget.onToggleTheme,
            icon: Icon(
                isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
          ),
          IconButton(
            tooltip: '下载任务',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DownloadsPage()),
            ),
            icon: const Icon(Icons.download_for_offline_rounded),
          ),
          IconButton(
            tooltip: '刷新接口配置',
            onPressed: _running ? null : _reloadConfig,
            icon: const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: <Widget>[
            if (_config.showHero) ...<Widget>[
              _buildHero(theme),
              const SizedBox(height: 18),
            ],
            if (_announce.isNotEmpty) ...<Widget>[
              _buildAnnouncement(theme),
              const SizedBox(height: 14),
            ],
            if (_remoteLoaded && _parsePassword.isEmpty) ...<Widget>[
              _buildPwdMissingBanner(theme),
              const SizedBox(height: 14),
            ],
            if (_limit != null) ...<Widget>[
              _buildLimitBar(theme),
              const SizedBox(height: 14),
            ],
            Text('分享链接', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            TextField(
              controller: _linkController,
              focusNode: _linkFocus,
              enabled: !_running,
              maxLines: 3,
              minLines: 3,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: '粘贴百度网盘分享链接（可含提取码与说明文字）',
                suffixIcon: IconButton(
                  tooltip: '粘贴',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: _running ? null : _pasteFromClipboard,
                ),
              ),
            ),
            // 站点可隐藏该输入框，但链接未带提取码时用户仍需手动填写，
            // 因此这里始终展示，避免「提取码错误」时无从修改。
            const SizedBox(height: 12),
            TextField(
              controller: _pwdController,
              enabled: !_running,
              decoration: const InputDecoration(
                labelText: '提取码',
                hintText: '4 位提取码（链接已带 ?pwd= 或已自动识别时可留空）',
              ),
            ),
            if (_config.showTokenInput) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: _tokenController,
                enabled: !_running,
                decoration: InputDecoration(
                  labelText: 'Token',
                  hintText: '默认 guest，可填自己的账号 token',
                  suffixIcon: IconButton(
                    tooltip: '应用',
                    icon: const Icon(Icons.check_circle_outline_rounded),
                    onPressed: _running ? null : _applyToken,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _running ? null : _startList,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.folder_open_rounded),
                label: Text(_running ? '处理中…' : '读取文件列表'),
              ),
            ),
            if (_statusText != null) ...<Widget>[
              const SizedBox(height: 16),
              _buildStatusRow(theme),
            ],
            if (_errorText != null) ...<Widget>[
              const SizedBox(height: 14),
              _buildError(theme),
            ],
            if (_vcode.hitCaptcha) ...<Widget>[
              const SizedBox(height: 14),
              _buildVcodeBanner(theme),
            ],
            if (_listing != null) ...<Widget>[
              const SizedBox(height: 24),
              _buildFileSection(theme),
            ],
            if (_results.isNotEmpty) ...<Widget>[
              const SizedBox(height: 24),
              _buildSectionTitle(theme, '解析结果', Icons.link_rounded),
              const SizedBox(height: 12),
              ..._results.map((entry) => _buildResultCard(theme, entry)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHero(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF0A8CFF), Color(0xFF3AA6FF)],
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF0A8CFF).withValues(alpha: 0.26),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.cloud_download_rounded,
                color: Color(0xFF0A8CFF), size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '网盘直链解析',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '解析分享链接为直链，内置引擎多线程加速下载',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 尚未拿到解析密码时的引导条：一键直达密码查询页。
  Widget _buildPwdMissingBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.vpn_key_rounded, size: 18, color: AppColors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('尚未获取解析密码', style: theme.textTheme.titleMedium),
                const SizedBox(height: 5),
                Text(
                  '解析前需要先获取密码，点击右侧按钮完成人机验证即可自动获取。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _openPwdQuery,
            child: const Text('去获取'),
          ),
        ],
      ),
    );
  }

  Widget _buildAnnouncement(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.campaign_rounded,
                size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('公告', style: theme.textTheme.titleMedium),
                const SizedBox(height: 5),
                Text(
                  normalizeLineBreaks(_announce).trim(),
                  softWrap: true,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLimitBar(ThemeData theme) {
    final limit = _limit!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.speed_rounded, size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '剩余次数 ${limit.count} · 剩余容量 '
                  '${DownloadItem.formatBytes(limit.size)}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 3),
                Text(
                  '到期 ${limit.expiresAt}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusRow(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          if (_running)
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.check_circle_outline_rounded,
                size: 16, color: AppColors.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _statusText!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 18, color: AppColors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorText!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVcodeBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.verified_user_outlined,
              size: 18, color: AppColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '服务端要求图形验证码，请先填写后重新解析',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: _showVcodeDialog,
            child: const Text('填写'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(ThemeData theme, String title, IconData icon) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(title, style: theme.textTheme.titleMedium),
      ],
    );
  }

  Widget _buildFileSection(ThemeData theme) {
    final listing = _listing!;
    final files = listing.list.where((e) => e.category != -1).toList();
    final selectedFiles = files.where((e) => _selected.contains(e.fsId)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.list_alt_rounded, size: 18, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('文件列表', style: theme.textTheme.titleMedium),
            ),
            Text('当前目录 $_dir', style: theme.textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: <Widget>[
              for (final item in listing.list) _buildFileTile(theme, item),
              if (listing.list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('该目录下没有条目',
                      style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: _running ? null : _parseSelected,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(
              selectedFiles == 0
                  ? '解析直链'
                  : '解析直链（已选 $selectedFiles 个）',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFileTile(ThemeData theme, FileItem item) {
    final isUp = item.category == -1;
    final checked = _selected.contains(item.fsId);

    return InkWell(
      onTap: item.isDir ? () => _enterItem(item) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: <Widget>[
            if (isUp)
              const SizedBox(width: 48)
            else
              Checkbox(
                value: checked,
                onChanged: (value) => _toggleSelect(item, value),
              ),
            Icon(
              isUp
                  ? Icons.drive_file_move_outline
                  : (item.isDir
                      ? Icons.folder_rounded
                      : Icons.insert_drive_file_outlined),
              size: 20,
              color: item.isDir ? AppColors.warning : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.serverFilename,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: item.isDir ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              item.isDir ? '目录' : DownloadItem.formatBytes(item.size),
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted,
              ),
            ),
            if (item.isDir)
              Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(
      ThemeData theme, ({String url, String name, String ua}) entry) {
    final displayName = entry.name.trim().isNotEmpty
        ? entry.name.trim()
        : (DownloadManager.fileNameFromUrl(entry.url) ?? '直链');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.link_rounded,
                    size: 16, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            entry.url,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: () =>
                      _downloadWithEngine(entry.url, displayName, entry.ua),
                  icon: const Icon(Icons.rocket_launch_rounded, size: 18),
                  label: const Text('引擎下载'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: () => _copy(entry.url),
                child: const Text('复制'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
