import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/backend_api.dart';
import '../state/user_state.dart';
import 'forgot_password_page.dart';
import 'register_page.dart';
import 'select_interest_page.dart'; // 之後下一頁

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController accountController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController captchaController = TextEditingController();

  String captchaText = _generateCaptcha();
  bool _isLoggingIn = false;

  static String _generateCaptcha({int length = 5}) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  void _refreshCaptcha() {
    setState(() {
      captchaText = _generateCaptcha();
    });
  }

  String _normalizeCaptchaInput(String raw) {
    final trimmed = raw.trim();
    final buffer = StringBuffer();
    for (final unit in trimmed.codeUnits) {
      if (unit == 0x3000) {
        buffer.writeCharCode(0x20);
        continue;
      }
      if (unit >= 0xFF10 && unit <= 0xFF19) {
        buffer.writeCharCode(unit - 0xFEE0);
        continue;
      }
      if ((unit >= 0xFF21 && unit <= 0xFF3A) ||
          (unit >= 0xFF41 && unit <= 0xFF5A)) {
        buffer.writeCharCode(unit - 0xFEE0);
        continue;
      }
      buffer.writeCharCode(unit);
    }
    return buffer.toString().toUpperCase();
  }

  Future<void> _onLoginPressed() async {
    final captchaInput = _normalizeCaptchaInput(captchaController.text);
    if (captchaInput != captchaText.toUpperCase()) {
      _showMessage('驗證碼錯誤');
      return;
    }

    final account = accountController.text.trim();
    final password = passwordController.text;
    if (account.isEmpty || password.isEmpty) {
      _showMessage('請輸入帳號與密碼');
      return;
    }

    if ((UserState.displayName ?? '').isEmpty) {
      UserState.updateName(accountController.text);
    }

    setState(() {
      _isLoggingIn = true;
    });

    try {
      final user = await BackendApi.instance.login(
        account: account,
        password: password,
      );
      final name = user['username']?.toString();
      if (name != null && name.isNotEmpty) {
        UserState.updateName(name);
      }
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SelectInterestPage()),
      );
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingIn = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 背景：跟 StartPage 一致的淡藍漸層
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFFEFF4FF),
              Color(0xFFE8ECFF),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // ← 返回箭頭
              // 主要卡片置中
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 520),
                    padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 32,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 標題
                        Center(
                          child: Text(
                            '歡迎登入！',
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w700,
                              color: Colors.black.withOpacity(0.9),
                              height: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),

                        // 帳號
                        const _FieldLabel(
                          text: '帳號',
                          icon: Icons.person,
                        ),
                        const SizedBox(height: 8),
                        _InputBox(
                          controller: accountController,
                          hintText: '請輸入帳號',
                        ),
                        const SizedBox(height: 20),

                        // 密碼
                        const _FieldLabel(
                          text: '密碼',
                          icon: Icons.key,
                        ),
                        const SizedBox(height: 8),
                        _InputBox(
                          controller: passwordController,
                          hintText: '請輸入密碼',
                          obscureText: true,
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const ForgotPasswordPage(),
                                ),
                              );
                            },
                            child: Text(
                              '忘記密碼？',
                              style: TextStyle(
                                color: Colors.black.withOpacity(0.7),
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),

                        // 驗證碼
                        const _FieldLabel(
                          text: '驗證碼',
                          icon: Icons.shield,
                        ),
                        const SizedBox(height: 8),

                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 72,
                                child: _InputBox(
                                  controller: captchaController,
                                  hintText: '輸入右方文字',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: SizedBox(
                                height: 72,
                                child: CaptchaBox(
                                  text: captchaText,
                                  onRefresh: _refreshCaptcha,
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 32),

                        // Log In 按鈕
                        SizedBox(
                          width: double.infinity,
                          child: PhysicalModel(
                            color: Colors.transparent,
                            elevation: 16,
                            shadowColor: const Color(0x6683A7D8),
                            borderRadius: BorderRadius.circular(28),
                            child: SizedBox(
                              height: 64,
                              child: ElevatedButton(
                                onPressed:
                                    _isLoggingIn ? null : () => _onLoginPressed(),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFBFD7FF),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(28),
                                  ),
                                  elevation: 0,
                                ),
                                child: _isLoggingIn
                                    ? const SizedBox(
                                        width: 32,
                                        height: 32,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          valueColor:
                                              AlwaysStoppedAnimation(Colors.black87),
                                        ),
                                      )
                                    : Text(
                                        'Log In',
                                        style: GoogleFonts.dancingScript(
                                          fontSize: 32,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.black.withOpacity(0.9),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // 註冊連結
                        Center(
                          child: TextButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const RegisterPage(),
                                ),
                              ).then((value) {
                                if (value is String && value.isNotEmpty) {
                                  setState(() {});
                                }
                              });
                            },
                            child: Text(
                              '沒有帳戶？點此註冊',
                              style: TextStyle(
                                color: Colors.black.withOpacity(0.9),
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }
}

/// 簡易圖形驗證碼：文字 + 雜訊線條/圓點，並提供重新整理按鈕。
class CaptchaBox extends StatelessWidget {
  const CaptchaBox({
    super.key,
    required this.text,
    this.onRefresh,
  });

  final String text;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final seed = text.hashCode;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(
            color: Colors.black.withOpacity(0.2),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _CaptchaNoisePainter(seed: seed),
              ),
            ),
            _WarpedText(text: text),
            if (onRefresh != null)
              Positioned(
                right: 2,
                top: 2,
                child: InkWell(
                  onTap: onRefresh,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.6),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black.withOpacity(0.3), width: 0.7),
                    ),
                    child: const Icon(Icons.refresh, size: 12, color: Colors.black87),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CaptchaNoisePainter extends CustomPainter {
  _CaptchaNoisePainter({required this.seed});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rand = Random(seed);
    final bgPaint = Paint();
    for (var i = 0; i < 12; i++) {
      bgPaint.color = Color.fromARGB(
        110,
        150 + rand.nextInt(105),
        150 + rand.nextInt(105),
        170 + rand.nextInt(85),
      );
      final rect = Rect.fromLTWH(
        rand.nextDouble() * size.width,
        rand.nextDouble() * size.height,
        rand.nextDouble() * (size.width / 1.6),
        rand.nextDouble() * 20 + 8,
      );
      canvas.save();
      canvas.translate(rect.center.dx, rect.center.dy);
      canvas.rotate((rand.nextDouble() - 0.5) * 0.8);
      canvas.translate(-rect.center.dx, -rect.center.dy);
      canvas.drawRect(rect, bgPaint);
      canvas.restore();
    }

    final linePaint = Paint()
      ..color = Colors.black.withOpacity(0.12)
      ..strokeWidth = 1.3;

    for (var i = 0; i < 10; i++) {
      final p1 = Offset(rand.nextDouble() * size.width, rand.nextDouble() * size.height);
      final p2 = Offset(rand.nextDouble() * size.width, rand.nextDouble() * size.height);
      canvas.drawLine(p1, p2, linePaint);
    }

    final dotPaint = Paint()..color = Colors.black.withOpacity(0.2);
    for (var i = 0; i < 55; i++) {
      final center = Offset(rand.nextDouble() * size.width, rand.nextDouble() * size.height);
      canvas.drawCircle(center, rand.nextDouble() * 2.0 + 0.6, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _WarpedText extends StatelessWidget {
  const _WarpedText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final rand = Random(text.hashCode);
    return LayoutBuilder(
      builder: (context, constraints) {
        final baseWidth = constraints.maxWidth - 16;
        final spacing = baseWidth / text.length;
        final startX = -baseWidth / 2 + spacing / 2;
        final letters = <Widget>[];
        for (var i = 0; i < text.length; i++) {
          final ch = text[i];
          final angle = (rand.nextDouble() - 0.5) * 0.4;
          final dy = (rand.nextDouble() - 0.5) * 5;
          final scale = 0.9 + rand.nextDouble() * 0.35;
          final color = Color.fromARGB(
            255,
            50 + rand.nextInt(150),
            50 + rand.nextInt(150),
            50 + rand.nextInt(150),
          );
          letters.add(Transform.translate(
            offset: Offset(startX + spacing * i, dy),
            child: Transform.rotate(
              angle: angle,
              child: Transform.scale(
                scale: scale,
                child: Text(
                  ch,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ),
          ));
        }
        return Center(
          child: SizedBox(
            height: 40,
            width: baseWidth,
            child: Stack(
              alignment: Alignment.center,
              children: letters,
            ),
          ),
        );
      },
    );
  }
}

/// label + icon，小標題列
class _FieldLabel extends StatelessWidget {
  final String text;
  final IconData icon;
  const _FieldLabel({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.black.withOpacity(0.9),
          ),
        ),
        const SizedBox(width: 6),
        Icon(
          icon,
          size: 20,
          color: Colors.black.withOpacity(0.9),
        ),
      ],
    );
  }
}

/// 共用輸入框
class _InputBox extends StatelessWidget {
  final TextEditingController controller;
  final String? hintText;
  final bool obscureText;

  const _InputBox({
    required this.controller,
    this.hintText,
    this.obscureText = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.06),
          blurRadius: 12,
          offset: const Offset(0, 6),
        ),
      ]),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          hintText: hintText,
          hintStyle: TextStyle(
            color: Colors.black.withOpacity(0.4),
            fontSize: 16,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
