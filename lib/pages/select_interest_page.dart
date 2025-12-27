import 'package:flutter/material.dart';
import '../data/interest_data.dart';
import '../services/backend_api.dart';
import '../state/user_state.dart';
import 'home_page.dart';

class SelectInterestPage extends StatefulWidget {
  const SelectInterestPage({super.key});

  @override
  State<SelectInterestPage> createState() => _SelectInterestPageState();
}

class _SelectInterestPageState extends State<SelectInterestPage> {
  // 使用者目前勾選了哪些興趣 (用 id 存)
  final Set<String> _selected = {};

  // 各分類 + 內容
  final List<InterestCategory> groups = interestCategories;
  final BackendApi _api = BackendApi.instance;
  bool _submittingInterests = false;

  // 點選景點用
  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  // 有沒有達成至少 3 個
  bool get _canProceed => _selected.length >= 3;

  Future<void> _onNext() async {
    if (!_canProceed || _submittingInterests) return;

    setState(() {
      _submittingInterests = true;
    });

    try {
      await _api.submitInterests(_selected.toList());
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => HomePage(
            selectedInterestIds: _selected.toList(),
            displayName: UserState.displayName,
          ),
        ),
      );
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _submittingInterests = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const bgColor = Color(0xFFE6DCCF); // 淡米色
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Stack(
          children: [
            // (1) 主內容：標題 + 分類群組
            ListView(
              padding: const EdgeInsets.only(
                bottom: 200, // 預留給底部浮動卡片
                top: 24,
              ),
              children: [
                // 頂部大標題區
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 主標題：更大更醒目，靠左
                      const Text(
                        '請選擇 3 個以上你感興趣的地點',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: Colors.black87,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 細長分隔線，淺一點比較有質感
                      Container(
                        height: 2,
                        width: 220,
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 28),
                    ],
                  ),
                ),

                // 每一個分類群組 UI
                ...groups.map(_buildCategorySection),

                const SizedBox(height: 40),
              ],
            ),

            // (2) 底部浮動卡片（iOS抽屜風格，但不是貼滿）
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                // 離底邊一點，漂亮一點
                margin: const EdgeInsets.only(bottom: 30),
                // 讓它 90% 寬，左右留白
                width: size.width * 0.9,
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                decoration: BoxDecoration(
                  color: const Color(0xFFFDF9F1), // 更實的奶油白
                  borderRadius: BorderRadius.circular(28), // 四角圓角
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.22),
                      blurRadius: 32,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 已選幾個
                    Text(
                      '已選擇 ${_selected.length} / 3',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _canProceed ? Colors.black87 : Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 下一步按鈕
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _canProceed && !_submittingInterests
                            ? _onNext
                            : null,
                        style: ElevatedButton.styleFrom(
                          elevation: 0,
                          backgroundColor: _canProceed
                              ? const Color(0xFFBFD7FF) // 跟首頁按鈕同色
                              : Colors.grey.shade400,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                        child: _submittingInterests
                            ? const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  valueColor: AlwaysStoppedAnimation(
                                    Colors.black87,
                                  ),
                                ),
                              )
                            : Text(
                                '下一步',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  color: _canProceed
                                      ? Colors.black87
                                      : Colors.black45,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 單一分類區塊：標題 + 橫向滑動清單
  Widget _buildCategorySection(InterestCategory group) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分類標題（靠左）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              group.title,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 橫向滑動的一排圓圖
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: group.items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 20),
              itemBuilder: (context, index) {
                final item = group.items[index];
                final isSelected = _selected.contains(item.id);
                return _InterestBubble(
                  label: item.label,
                  imagePath: item.imagePath,
                  isSelected: isSelected,
                  onTap: () => _toggleSelect(item.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

/// =============== 單一興趣圓圖元件 ===============

class _InterestBubble extends StatelessWidget {
  final String label;
  final String imagePath;
  final bool isSelected;
  final VoidCallback onTap;

  const _InterestBubble({
    required this.label,
    required this.imagePath,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 110,
        child: Column(
          children: [
            Stack(
              children: [
                // 圓形圖片
                ClipOval(
                  child: Image.asset(
                    imagePath,
                    width: 110,
                    height: 110,
                    fit: BoxFit.cover,
                  ),
                ),

                // 點過 → 半透明黑罩
                if (isSelected)
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withOpacity(0.28),
                    ),
                  ),

                // 點過 → 右上角藍色勾勾
                if (isSelected)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.lightBlue,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // 標籤文字
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.blue.shade800 : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =============== 資料結構 ===============
