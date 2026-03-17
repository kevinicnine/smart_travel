import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/backend_api.dart';
import '../state/user_state.dart';
import 'edit_profile_page.dart';
import 'select_interest_page.dart';
import 'change_password_page.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  String get _name => UserState.displayName ?? '旅人';
  String? get _avatar => UserState.avatarPath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE2D6C9),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 16),
              CircleAvatar(
                radius: 44,
                backgroundColor: Colors.white,
                backgroundImage: _avatar == null
                    ? null
                    : FileImage(File(_avatar!)),
                child: _avatar == null
                    ? Icon(Icons.pets, size: 44, color: Colors.brown.shade400)
                    : null,
              ),
              const SizedBox(height: 12),
              Text(
                _name,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 32),
              _AccountActionTile(
                icon: Icons.edit_note_outlined,
                label: '編輯個人資料',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const EditProfilePage()),
                  ).then((updated) {
                    if (updated == true) {
                      setState(() {});
                    }
                  });
                },
              ),
              _AccountActionTile(
                icon: Icons.vpn_key_outlined,
                label: '變更密碼',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ChangePasswordPage(),
                    ),
                  );
                },
              ),
              _AccountActionTile(
                icon: Icons.brush_outlined,
                label: '修改景點偏好',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SelectInterestPage(),
                    ),
                  );
                },
              ),
              _AccountActionTile(
                icon: Icons.chat_outlined,
                label: UserState.lineLinked ? 'LINE 通知已綁定' : '綁定 LINE 通知',
                subtitle: UserState.lineLinked
                    ? '已開啟 LINE 推播，可發送測試訊息'
                    : '產生綁定碼，到 LINE 官方帳號傳送即可完成綁定',
                onTap: () => _showLineBindingDialog(context),
              ),
              _AccountActionTile(
                icon: Icons.settings_outlined,
                label: '其他設定',
                onTap: () => _showComingSoon(context),
              ),
              _AccountActionTile(
                icon: Icons.logout,
                label: '登出',
                onTap: () =>
                    Navigator.popUntil(context, (route) => route.isFirst),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: 4,
        selectedItemColor: const Color(0xFF7A91C9),
        unselectedItemColor: Colors.black54,
        type: BottomNavigationBarType.fixed,
        onTap: (index) {
          if (index != 4) {
            Navigator.pop(context, index);
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: '首頁'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: '地圖'),
          BottomNavigationBarItem(icon: Icon(Icons.favorite), label: '收藏'),
          BottomNavigationBarItem(icon: Icon(Icons.route_rounded), label: '旅程'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '帳戶'),
        ],
      ),
    );
  }

  void _showComingSoon(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('功能開發中')));
  }

  Future<void> _showLineBindingDialog(BuildContext context) async {
    final userId = UserState.userId;
    if (userId == null || userId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('請先重新登入，再進行 LINE 綁定。')));
      return;
    }

    Map<String, dynamic>? binding;
    var linked = UserState.lineLinked;
    var pushEnabled = UserState.linePushEnabled;
    var loading = true;
    String? error;
    var initialized = false;
    var requestInFlight = false;

    Future<void> loadStatus(StateSetter setModalState) async {
      if (requestInFlight) return;
      requestInFlight = true;
      setModalState(() {
        loading = true;
        error = null;
      });
      try {
        final status = await BackendApi.instance.fetchLineLinkStatus(
          userId: userId,
        );
        linked = status['linked'] == true;
        pushEnabled = status['linePushEnabled'] == true;
        await UserState.updateUser(linked: linked, pushEnabled: pushEnabled);
        if (!linked) {
          final codeResult = await BackendApi.instance.createLineLinkCode(
            userId: userId,
          );
          binding = codeResult['binding'] as Map<String, dynamic>?;
        }
      } on ApiClientException catch (e) {
        error = e.message;
      } finally {
        requestInFlight = false;
        setModalState(() {
          loading = false;
        });
      }
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            if (!initialized) {
              initialized = true;
              Future.microtask(() => loadStatus(setModalState));
            }
            return AlertDialog(
              title: const Text('LINE 通知綁定'),
              content: SizedBox(
                width: 380,
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (error != null) ...[
                            Text(
                              error!,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (linked) ...[
                            const Text(
                              '已綁定 LINE 官方帳號，現在可以接收推播通知。',
                              style: TextStyle(fontSize: 15),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              pushEnabled ? 'LINE 推播：已開啟' : 'LINE 推播：未開啟',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ] else ...[
                            const Text(
                              '1. 加入你的 LINE 官方帳號好友\n2. 把下方綁定碼傳給 LINE Bot\n3. 收到成功訊息後回到 app 重新整理',
                              style: TextStyle(fontSize: 15, height: 1.5),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF5F0FF),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '綁定碼',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.black54,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    binding?['code']?.toString() ?? '尚未產生',
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '有效至：${binding?['expiresAt']?.toString().replaceFirst('T', ' ').substring(0, 16) ?? '-'}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: binding?['code'] == null
                                        ? null
                                        : () async {
                                            await Clipboard.setData(
                                              ClipboardData(
                                                text: binding!['code'].toString(),
                                              ),
                                            );
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text('綁定碼已複製'),
                                              ),
                                            );
                                          },
                                    child: const Text('複製綁定碼'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: binding?['addFriendUrl'] == null
                                        ? null
                                        : () async {
                                            await Clipboard.setData(
                                              ClipboardData(
                                                text: binding!['addFriendUrl']
                                                    .toString(),
                                              ),
                                            );
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text('加好友連結已複製'),
                                              ),
                                            );
                                          },
                                    child: const Text('複製加好友連結'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('關閉'),
                ),
                TextButton(
                  onPressed: () => loadStatus(setModalState),
                  child: const Text('重新整理'),
                ),
                if (linked)
                  FilledButton(
                    onPressed: () async {
                      try {
                        await BackendApi.instance.sendLinePushTest(userId: userId);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已送出 LINE 測試推播')),
                        );
                      } on ApiClientException catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(e.message)),
                        );
                      }
                    },
                    child: const Text('測試推播'),
                  ),
              ],
            );
          },
        );
      },
    );
    if (mounted) {
      setState(() {});
    }
  }
}

class _AccountActionTile extends StatelessWidget {
  const _AccountActionTile({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        leading: Icon(icon, color: Colors.black87),
        title: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
