import 'package:flutter/material.dart';
import '../widgets/glass.dart';

/// Sodda, tez va chiroyli fon — blur yo'q, bitta Container.
/// Barcha ekranlarda bir xil ko'rinadi.
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bg,
      child: child,
    );
  }
}
