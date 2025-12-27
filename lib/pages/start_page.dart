import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'login_page.dart';

class StartPage extends StatelessWidget {
  const StartPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 整個頁面是淡藍背景，底下再鋪圖
      body: Stack(
        children: [
          // 1. 背景圖 (整張 figma export 下來的 start_bg.png)
          Positioned.fill(
            child: Image.asset(
              'assets/images/start_bg.png',
              fit: BoxFit.cover,
            ),
          ),

          // 2. 內容 (標題 + 副標 + 描述 + 按鈕)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ------------- 上面文字區塊 -------------
                  const SizedBox(height: 120),

                  // 主標題：智慧旅遊系統
                  Text(
                    "智慧旅遊系統",
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withOpacity(0.9),
                      height: 1.2,
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 英文副標
                  Text(
                    "Smart Itinerary Planning System",
                    style: TextStyle(
                      fontSize: 20,
                      fontStyle: FontStyle.italic,
                      color: Colors.black.withOpacity(0.6),
                      height: 1.3,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // 說明文字
                  Text(
                    "AI 幫你量身訂做旅遊行程！",
                    style: TextStyle(
                      fontSize: 20,
                      color: Colors.black.withOpacity(0.85),
                      height: 1.4,
                    ),
                  ),

                  // 撐開，讓按鈕留在畫面下半部
                  const Spacer(),

                  // ------------- Let's Start! 按鈕 -------------
                  Center(
                    child: PhysicalModel(
                      color: Colors.transparent,
                      elevation: 16,
                      shadowColor: Colors.black.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(24),
                      child: SizedBox(
                        width: 360,
                        height: 90,
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const LoginPage(),
                              ),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFC9D6FF),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            elevation: 0,
                          ),
                          child: Text(
                            "Let's Start!",
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

                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}