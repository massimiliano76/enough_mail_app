import 'package:flutter/material.dart';

class PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String labelText;
  final String hintText;
  final Function(String) onChanged;
  PasswordField(
      {Key key,
      @required this.controller,
      this.labelText,
      this.hintText,
      this.onChanged})
      : super(key: key);

  @override
  _PasswordFieldState createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool obscureText = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: obscureText,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        hintText: widget.hintText,
        labelText: widget.labelText,
        suffixIcon: IconButton(
          icon: Icon(obscureText ? Icons.lock_open : Icons.lock),
          onPressed: () {
            setState(
              () => obscureText = !obscureText,
            );
          },
        ),
      ),
    );
  }
}
