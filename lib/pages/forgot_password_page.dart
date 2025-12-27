import 'package:flutter/material.dart';
import '../services/backend_api.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final TextEditingController accountController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController codeController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController confirmController = TextEditingController();

  bool codeSent = false;
  bool codeVerified = false;
  bool _sendingCode = false;
  bool _verifyingCode = false;
  bool _resettingPassword = false;

  final BackendApi _api = BackendApi.instance;

  @override
  void dispose() {
    accountController.dispose();
    emailController.dispose();
    codeController.dispose();
    passwordController.dispose();
    confirmController.dispose();
    super.dispose();
  }

  Future<void> _sendResetCode() async {
    final account = accountController.text.trim();
    final email = emailController.text.trim();

    if (account.isEmpty) {
      _showMessage('請輸入帳號');
      return;
    }
    if (email.isEmpty) {
      _showMessage('請輸入電子郵件');
      return;
    }

    setState(() {
      _sendingCode = true;
      codeVerified = false;
    });

    try {
      final data = await _api.sendPasswordResetCode(
        account: account,
        email: email,
      );
      setState(() {
        codeSent = true;
      });
      final debug = data['debugCode']?.toString();
      _showMessage(
        debug == null ? '已寄送驗證碼至信箱' : '已寄送驗證碼 (debug: $debug)',
      );
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _sendingCode = false;
        });
      }
    }
  }

  Future<void> _verifyCode() async {
    if (!codeSent) {
      _showMessage('請先寄送驗證碼');
      return;
    }

    if (codeController.text.trim().isEmpty) {
      _showMessage('請輸入驗證碼');
      return;
    }

    setState(() {
      _verifyingCode = true;
    });

    try {
      await _api.verifyPasswordResetCode(
        account: accountController.text.trim(),
        email: emailController.text.trim(),
        code: codeController.text.trim(),
      );
      setState(() {
        codeVerified = true;
      });
      _showMessage('驗證成功');
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _verifyingCode = false;
        });
      }
    }
  }

  Future<void> _resetPassword() async {
    final account = accountController.text.trim();
    final email = emailController.text.trim();
    final password = passwordController.text;
    final confirm = confirmController.text;

    if (account.isEmpty) {
      _showMessage('請輸入帳號');
      return;
    }

    if (email.isEmpty) {
      _showMessage('請輸入電子郵件');
      return;
    }

    if (!codeSent || !codeVerified) {
      _showMessage('請先完成驗證碼寄送與驗證');
      return;
    }

    if (password.length < 6) {
      _showMessage('新密碼長度至少 6 碼');
      return;
    }

    if (password != confirm) {
      _showMessage('兩次輸入的密碼不一致');
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _resettingPassword = true;
    });

    try {
      await _api.completePasswordReset(
        account: account,
        email: email,
        code: codeController.text.trim(),
        newPassword: password,
      );
      _showMessage('已為 $account 重設密碼，請回登入頁使用新密碼');
      if (!mounted) return;
      Navigator.pop(context);
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _resettingPassword = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          bottom: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.black87),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '忘記密碼',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                const SizedBox(height: 32),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 520),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
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
                      const _FieldLabel(text: '帳號'),
                      const SizedBox(height: 8),
                      _InputBox(
                        controller: accountController,
                        hintText: '請輸入帳號',
                      ),
                      const SizedBox(height: 24),
                      const _FieldLabel(text: '電子郵件'),
                      const SizedBox(height: 8),
                      _InputBox(
                        controller: emailController,
                        hintText: 'example@mail.com',
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed:
                              _sendingCode ? null : () => _sendResetCode(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFBDD2FF),
                            foregroundColor: Colors.black87,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _sendingCode
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    valueColor:
                                        AlwaysStoppedAnimation(Colors.black87),
                                  ),
                                )
                              : Text(codeSent ? '重新寄送驗證碼' : '寄送驗證碼'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const _FieldLabel(text: '驗證碼'),
                          if (codeVerified)
                            const _StatusTag(
                              text: '已驗證',
                              color: Colors.green,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _InputBox(
                              controller: codeController,
                              hintText: '輸入驗證碼',
                              textCapitalization: TextCapitalization.characters,
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 56,
                            child: ElevatedButton(
                              onPressed: codeVerified || _verifyingCode
                                  ? null
                                  : () => _verifyCode(),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFBDD2FF),
                                foregroundColor: Colors.black87,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: _verifyingCode
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        valueColor: AlwaysStoppedAnimation(
                                            Colors.black87),
                                      ),
                                    )
                                  : Text(codeVerified ? '已驗證' : '驗證'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const _FieldLabel(text: '新密碼'),
                      const SizedBox(height: 8),
                      _InputBox(
                        controller: passwordController,
                        hintText: '請輸入新密碼',
                        obscureText: true,
                      ),
                      const SizedBox(height: 20),
                      const _FieldLabel(text: '確認密碼'),
                      const SizedBox(height: 8),
                      _InputBox(
                        controller: confirmController,
                        hintText: '再次輸入新密碼',
                        obscureText: true,
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed:
                              _resettingPassword ? null : () => _resetPassword(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFBFD7FF),
                            foregroundColor: Colors.black87,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 8,
                          ),
                          child: _resettingPassword
                              ? const SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    valueColor:
                                        AlwaysStoppedAnimation(Colors.black87),
                                  ),
                                )
                              : const Text(
                                  '設定新密碼',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Colors.black.withOpacity(0.9),
      ),
    );
  }
}

class _InputBox extends StatelessWidget {
  final TextEditingController controller;
  final String? hintText;
  final bool obscureText;
  final TextCapitalization textCapitalization;
  final TextInputType? keyboardType;

  const _InputBox({
    required this.controller,
    this.hintText,
    this.obscureText = false,
    this.textCapitalization = TextCapitalization.none,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        textCapitalization: textCapitalization,
        keyboardType: keyboardType,
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

class _StatusTag extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusTag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
