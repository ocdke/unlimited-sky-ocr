// "无境天" 水印
//
// 放在各功能栏的最后。刻意做得克制: 细分割线 + 字距拉开的小字 + 极低对比度,
// 目的是"署名"而不是抢视线。

import 'package:flutter/material.dart';

class SkyWatermark extends StatelessWidget {
  const SkyWatermark({super.key, this.compact = false});

  /// 紧凑模式 (实时模式的控制条用, 那边空间小)
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: compact ? 8 : 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 细分割线
          Container(
            width: 1,
            height: compact ? 13 : 15,
            margin: EdgeInsets.only(right: compact ? 8 : 10),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x00FFFFFF),
                  Color(0x33FFFFFF),
                  Color(0x00FFFFFF),
                ],
              ),
            ),
          ),
          // 一个极小的星点, 让水印不那么"平"
          Container(
            width: 3,
            height: 3,
            margin: const EdgeInsets.only(right: 7),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                Color(0xCC7FD8FF),
                Color(0x007FD8FF),
              ]),
            ),
          ),
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFE8F4FF),
                Color(0xFF8FB6D9),
              ],
            ).createShader(r),
            child: Text(
              '无境天',
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w500,
                letterSpacing: compact ? 2.5 : 3.5,
                height: 1.0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
