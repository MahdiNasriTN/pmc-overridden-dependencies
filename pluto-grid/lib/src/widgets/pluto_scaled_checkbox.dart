import 'package:flutter/material.dart';

class PlutoScaledCheckbox extends StatelessWidget {
  final bool? value;
  final Function(bool? changed) handleOnChanged;
  final bool tristate;
  final double scale;
  final Color unselectedColor;
  final Color? activeColor;
  final Color checkColor;

  const PlutoScaledCheckbox({
    Key? key,
    required this.value,
    required this.handleOnChanged,
    this.tristate = false,
    this.scale = 1.0,
    this.unselectedColor = const Color(0xFFD0D0D0), // lighter gray border
    this.activeColor = Colors.lightBlue,
    this.checkColor = const Color(0xFFDCF5FF),
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      child: Theme(
        data: ThemeData(
          unselectedWidgetColor: unselectedColor,
        ),
        child: Checkbox(
          value: value,
          tristate: tristate,
          onChanged: handleOnChanged,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3.0), // smaller radius, closer to your example
          ),
          fillColor: MaterialStateProperty.resolveWith<Color?>((states) {
            if (states.contains(MaterialState.selected)) {
              return activeColor;
            }
            return Colors.white;
          }),
          side: BorderSide(
            color: unselectedColor,
            width: 1.0, // thinner border
          ),
          activeColor: value == null ? unselectedColor : activeColor,
          checkColor: checkColor,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
