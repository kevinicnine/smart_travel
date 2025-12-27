import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../state/user_state.dart';
import '../services/backend_api.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  // 文字輸入控制器
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController emailCodeController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController confirmController = TextEditingController();

  // 假狀態：有沒有已經寄驗證碼/驗證成功
  bool emailCodeSent = false;
  bool emailVerified = false;

  bool _isRegistering = false;
  bool _sendingEmailCode = false;
  bool _verifyingEmailCode = false;

  final BackendApi _api = BackendApi.instance;

  // 送出註冊
  Future<void> _onRegisterPressed() async {
    final username = usernameController.text.trim();
    final email = emailController.text.trim();
    final pass = passwordController.text;
    final confirm = confirmController.text;

    if (username.isEmpty) {
      _showMessage('請輸入用戶名稱');
      return;
    }
    if (email.isEmpty) {
      _showMessage('請輸入電子郵件');
      return;
    }
    if (pass.length < 6) {
      _showMessage('密碼至少需要 6 碼');
      return;
    }
    if (pass != confirm) {
      _showMessage('兩次輸入的密碼不一致');
      return;
    }
    if (!emailVerified) {
      _showMessage('請先完成 Email 驗證');
      return;
    }

    setState(() {
      _isRegistering = true;
    });

    try {
      final user = await _api.register(
        username: username,
        email: email,
        phone: '',
        password: pass,
      );
      final name = user['username']?.toString() ?? username;
      UserState.updateName(name);
      _showMessage('註冊成功！');
      if (!mounted) return;
      Navigator.pop(context, name);
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _isRegistering = false;
        });
      }
    }
  }

  // 模擬寄出 email 驗證碼
  Future<void> _sendEmailCode() async {
    final email = emailController.text.trim();
    if (email.isEmpty) {
      _showMessage('請先輸入電子郵件');
      return;
    }

    setState(() {
      _sendingEmailCode = true;
      emailVerified = false;
    });

    try {
      final data = await _api.sendEmailCode(email);
      setState(() {
        emailCodeSent = true;
      });
      final debugCode = data['debugCode']?.toString();
      _showMessage(
        debugCode == null ? '驗證碼已寄到你的信箱' : '驗證碼已寄出 (debug: $debugCode)',
      );
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _sendingEmailCode = false;
        });
      }
    }
  }

  // 模擬檢查 email 驗證碼
  Future<void> _verifyEmailCode() async {
    final email = emailController.text.trim();
    final code = emailCodeController.text.trim();
    if (email.isEmpty) {
      _showMessage('請先輸入電子郵件');
      return;
    }
    if (code.isEmpty) {
      _showMessage('請輸入信箱驗證碼');
      return;
    }

    setState(() {
      _verifyingEmailCode = true;
    });

    try {
      await _api.verifyEmailCode(email: email, code: code);
      setState(() {
        emailVerified = true;
      });
      _showMessage('Email 驗證成功');
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _verifyingEmailCode = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 背景顏色：跟你註冊頁截圖一樣那種淡淡藍灰
      backgroundColor: const Color(0xFFDDE2F1),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 標題置中
              const SizedBox(height: 8),
              const Text(
                '註冊帳號',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                  height: 1.2,
                ),
              ),

              const SizedBox(height: 32),

              // 使用者名稱
              const _FieldLabel(text: '用戶名稱'),
              const SizedBox(height: 8),
              _InputBox(controller: usernameController, hintText: '請輸入名稱'),

              const SizedBox(height: 20),

              // 電子郵件 + 寄送驗證碼
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const _FieldLabel(text: '電子郵件'),
                  // 狀態標籤 (已驗證)
                  if (emailVerified)
                    const _StatusTag(text: '已驗證', color: Colors.green),
                ],
              ),
              const SizedBox(height: 8),
              _InputBox(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                hintText: 'example@mail.com',
              ),

              const SizedBox(height: 12),

              // 驗證碼輸入 + 按鈕列
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _InputBox(
                      controller: emailCodeController,
                      hintText: '輸入Email驗證碼',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    children: [
                      SizedBox(
                        height: 40,
                        width: 88,
                        child: OutlinedButton(
                          onPressed: emailVerified || _sendingEmailCode
                              ? null
                              : () => _sendEmailCode(),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            side: BorderSide(
                              color: emailVerified
                                  ? Colors.grey
                                  : Colors.blueGrey.shade700,
                            ),
                            foregroundColor: emailVerified
                                ? Colors.grey
                                : Colors.blueGrey.shade700,
                            textStyle: const TextStyle(fontSize: 13),
                          ),
                          child: _sendingEmailCode
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('寄驗證碼'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 40,
                        width: 88,
                        child: OutlinedButton(
                          onPressed: emailVerified || _verifyingEmailCode
                              ? null
                              : () => _verifyEmailCode(),
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            side: BorderSide(
                              color: emailVerified
                                  ? Colors.green
                                  : Colors.blueGrey.shade700,
                            ),
                            foregroundColor:
                                emailVerified ? Colors.green : Colors.blueGrey.shade700,
                            textStyle: const TextStyle(fontSize: 13),
                          ),
                          child: _verifyingEmailCode
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(emailVerified ? '已通過' : '驗證'),
                        ),
                      ),
                    ],
                  )
                ],
              ),

              const SizedBox(height: 20),

              // 密碼
              const _FieldLabel(text: '密碼'),
              const SizedBox(height: 8),
              _InputBox(
                controller: passwordController,
                obscureText: true,
                hintText: '請輸入密碼',
              ),

              const SizedBox(height: 20),

              // 再次確認密碼
              const _FieldLabel(text: '再次確認密碼'),
              const SizedBox(height: 8),
              _InputBox(
                controller: confirmController,
                obscureText: true,
                hintText: '再次輸入密碼',
              ),

              const SizedBox(height: 28),

              // Register 按鈕 (跟你Figma那種藍色膠囊+手寫字感)
              SizedBox(
                height: 56,
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isRegistering ? null : () => _onRegisterPressed(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFBFD7FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    elevation: 8,
                    shadowColor: const Color(0x6683A7D8),
                  ),
                  child: _isRegistering
                      ? const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation(Colors.black87),
                          ),
                        )
                      : Text(
                          "Register",
                          style: GoogleFonts.dancingScript(
                            fontSize: 28,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 24),

              // 返回登入
              TextButton(
                onPressed: () {
                  Navigator.pop(context); // 回登入頁
                },
                child: const Text(
                  '已有帳戶？返回登入',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 16,
                  ),
                ),
              ),

              const SizedBox(height: 24),
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

/// 小標籤 (用戶名稱 / 電子郵件 / 手機 / 密碼...)
class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 16,
          color: Colors.black87,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 狀態標籤（已驗證）
class _StatusTag extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusTag({
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 可重複使用輸入框
class _InputBox extends StatelessWidget {
  final TextEditingController controller;
  final bool obscureText;
  final String? hintText;
  final TextInputType? keyboardType;

  const _InputBox({
    required this.controller,
    this.obscureText = false,
    this.hintText,
    this.keyboardType,
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
        keyboardType: keyboardType,
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          hintText: hintText,
          hintStyle: const TextStyle(
            color: Colors.black38,
            fontSize: 14,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
