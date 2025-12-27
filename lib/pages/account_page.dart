import 'dart:io';

import 'package:flutter/material.dart';
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
                    MaterialPageRoute(builder: (_) => const ChangePasswordPage()),
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
          if (index == 0) {
            Navigator.pop(context);
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: '首頁'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: '地圖'),
          BottomNavigationBarItem(icon: Icon(Icons.favorite), label: '收藏'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: '歷史'),
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
}

class _AccountActionTile extends StatelessWidget {
  const _AccountActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
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
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
