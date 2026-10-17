import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/models.dart';
import 'core/remote_config.dart';
import 'theme/app_theme.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const TierFlowApp());
}

/// 应用外壳：负责主题切换，并在启动时先拉取站点配置再进入主界面。
class TierFlowApp extends StatefulWidget {
  const TierFlowApp({super.key});

  @override
  State<TierFlowApp> createState() => _TierFlowAppState();
}

class _TierFlowAppState extends State<TierFlowApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '百度公益解析',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: _themeMode,
      // AppTheme.light / AppTheme.dark 在构造时会调用 AppColors.setBrightness，
      // 后构造的 darkTheme 会把全局调色板遗留在深色。这里按最终生效的亮度重新同步。
      builder: (context, child) {
        AppColors.setBrightness(Theme.of(context).brightness);
        return child ?? const SizedBox.shrink();
      },
      home: _Bootstrap(onToggleTheme: _toggleTheme),
    );
  }
}

/// 启动引导：读取本地 token 并拉取站点配置，成功后进入主界面。
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({required this.onToggleTheme});

  final VoidCallback onToggleTheme;

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  final ParseApiClient _client = ParseApiClient();

  late Future<ParseConfig> _future;

  @override
  void initState() {
    super.initState();
    _future = _boot();
  }

  Future<ParseConfig> _boot() async {
    // 先从自有后端拉取运行配置，用其中的 parseApiBase 覆盖内置域名，
    // 保证首个业务请求就走云端下发的接口地址。
    final remote = await RemoteConfigService().load();
    final base = remote?.parseApiBase.trim() ?? '';
    if (base.isNotEmpty) _client.baseUrl = base;
    await _client.loadToken();
    return _client.getConfig();
  }

  Future<ParseConfig> _reload() async {
    // 手动刷新时强制重新拉取云端配置，并同步最新的接口域名。
    final remote = await RemoteConfigService().load(useCache: false);
    final base = remote?.parseApiBase.trim() ?? '';
    if (base.isNotEmpty) _client.baseUrl = base;
    final config = await _client.getConfig();
    if (mounted) setState(() => _future = Future<ParseConfig>.value(config));
    return config;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ParseConfig>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _BootScaffold(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                SizedBox(height: 20),
                Text('正在获取接口配置…'),
              ],
            ),
          );
        }

        if (snapshot.hasError) {
          return _BootScaffold(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.cloud_off_outlined, size: 56),
                  const SizedBox(height: 18),
                  Text('配置加载失败',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () => setState(() => _future = _boot()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }

        return HomePage(
          client: _client,
          config: snapshot.data!,
          onReloadConfig: _reload,
          onToggleTheme: widget.onToggleTheme,
        );
      },
    );
  }
}

class _BootScaffold extends StatelessWidget {
  const _BootScaffold({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: child));
  }
}
