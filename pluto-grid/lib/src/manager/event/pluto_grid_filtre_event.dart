import 'package:pluto_grid/pluto_grid.dart';

class PlutoGridResetAllFiltersEvent extends PlutoGridEvent {
  PlutoGridResetAllFiltersEvent() : super(type: PlutoGridEventType.normal);

  @override
  void handler(PlutoGridStateManager stateManager) {
    print('from handler ${stateManager.refRows.length}');
    stateManager?.setFilter((element) => true);

    stateManager.notifyListeners();
  }
}
