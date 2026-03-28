import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';

class CrossAuthView extends StatefulWidget {
  final String? accessToken;
  final String? refreshToken;

  const CrossAuthView({super.key, this.accessToken, this.refreshToken});

  @override
  State<CrossAuthView> createState() => _CrossAuthViewState();
}

class _CrossAuthViewState extends State<CrossAuthView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go(AppRoutes.login);
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
