import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../state/user_state.dart';

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;
  late final TextEditingController _genderController;
  late final TextEditingController _birthdayController;
  late final TextEditingController _addressController;
  final ImagePicker _picker = ImagePicker();
  String? _avatarPath;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: UserState.displayName ?? '');
    _emailController = TextEditingController();
    _phoneController = TextEditingController();
    _genderController = TextEditingController();
    _birthdayController = TextEditingController();
    _addressController = TextEditingController();
    _avatarPath = UserState.avatarPath;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _genderController.dispose();
    _birthdayController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE2D6C9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFE2D6C9),
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: _pickAvatar,
                child: CircleAvatar(
                  radius: 52,
                  backgroundColor: Colors.white,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircleAvatar(
                        radius: 48,
                        backgroundColor: Colors.white,
                        backgroundImage: _avatarPath == null
                            ? null
                            : FileImage(File(_avatarPath!)),
                        child: _avatarPath == null
                            ? Icon(
                                Icons.pets,
                                size: 50,
                                color: Colors.brown.shade400,
                              )
                            : null,
                      ),
                      Positioned(
                        bottom: 4,
                        right: 4,
                        child: Material(
                          color: Colors.black.withOpacity(0.6),
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _pickAvatar,
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(
                                Icons.camera_alt,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _pickAvatar,
                child: const Text(
                  '編輯照片',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 28),
              _buildField('用戶名稱', _nameController),
              _buildField('電子郵件', _emailController),
              _buildField('手機', _phoneController),
              _buildField('性別', _genderController),
              _buildField('生日', _birthdayController),
              _buildField('地址', _addressController),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _onSave,
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: const Color(0xFFD8DDEF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: const Text(
                    '完成編輯',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
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

  Widget _buildField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
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
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
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

  void _onSave() {
    final updatedName = _nameController.text.trim();
    if (updatedName.isNotEmpty) {
      UserState.updateName(updatedName);
    }
    if (_avatarPath != null) {
      UserState.updateAvatar(_avatarPath!);
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('資料已更新')));
    Navigator.pop(context, true);
  }

  Future<void> _pickAvatar() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null) {
        _showSnack('未選擇照片');
        return;
      }
      if (!mounted) return;
      setState(() {
        _avatarPath = picked.path;
      });
      _showSnack('已更新照片');
    } catch (error) {
      if (!mounted) return;
      _showSnack('開啟相簿失敗：$error');
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
