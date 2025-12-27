import 'package:flutter/material.dart';

import '../services/backend_api.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  final BackendApi _api = BackendApi.instance;

  bool _isSendingCode = false;
  bool _isVerifyingCode = false;
  bool _isSubmitting = false;
  bool _codeVerified = false;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE2D6C9),
      appBar: AppBar(
        title: const Text('變更密碼'),
        backgroundColor: const Color(0xFFE2D6C9),
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildField('電子郵件', _emailController),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _buildField('驗證碼', _codeController)),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    onPressed: _isSendingCode ? null : _onSendCode,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7A91C9),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      minimumSize: const Size(90, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isSendingCode
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : const Text('寄驗證碼'),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    onPressed: _isVerifyingCode ? null : _onVerifyCode,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _codeVerified
                          ? Colors.green
                          : Colors.black87,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      minimumSize: const Size(80, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isVerifyingCode
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : Text(_codeVerified ? '已驗證' : '驗證'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildField(
                '舊密碼（僅顯示，不會送出）',
                _oldPasswordController,
                obscure: true,
              ),
              _buildField('新密碼', _newPasswordController, obscure: true),
              _buildField('確認新密碼', _confirmPasswordController, obscure: true),
              const SizedBox(height: 18),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _onSubmit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7A91C9),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : const Text(
                          '更新密碼',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '說明：系統目前以「寄驗證碼到信箱」的方式變更密碼，舊密碼欄位僅供記錄，實際驗證以 Email 驗證碼為準。',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.black54,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController controller, {
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            obscureText: obscure,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onSendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showSnack('請輸入電子郵件');
      return;
    }
    setState(() => _isSendingCode = true);
    try {
      await _api.sendPasswordResetCode(account: email, email: email);
      _showSnack('驗證碼已寄出');
    } catch (e) {
      _showSnack('寄送失敗：$e');
    } finally {
      if (mounted) setState(() => _isSendingCode = false);
    }
  }

  Future<void> _onVerifyCode() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    if (email.isEmpty || code.isEmpty) {
      _showSnack('請輸入 Email 與驗證碼');
      return;
    }
    setState(() => _isVerifyingCode = true);
    try {
      await _api.verifyPasswordResetCode(
        account: email,
        email: email,
        code: code,
      );
      setState(() => _codeVerified = true);
      _showSnack('驗證成功');
    } catch (e) {
      _showSnack('驗證失敗：$e');
    } finally {
      if (mounted) setState(() => _isVerifyingCode = false);
    }
  }

  Future<void> _onSubmit() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    final newPassword = _newPasswordController.text;
    final confirm = _confirmPasswordController.text;
    if (email.isEmpty ||
        code.isEmpty ||
        newPassword.isEmpty ||
        confirm.isEmpty) {
      _showSnack('請完整填寫 Email、驗證碼與新密碼');
      return;
    }
    if (newPassword != confirm) {
      _showSnack('新密碼與確認密碼不一致');
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      await _api.completePasswordReset(
        account: email,
        email: email,
        code: code,
        newPassword: newPassword,
      );
      if (!mounted) return;
      _showSnack('密碼已更新，請重新登入');
      Navigator.pop(context);
    } catch (e) {
      _showSnack('更新失敗：$e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
