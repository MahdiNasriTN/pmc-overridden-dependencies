import 'dart:async';
import 'dart:convert';

import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ui.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:get_storage/get_storage.dart';

class PlutoColumnFilter extends PlutoStatefulWidget {
  final PlutoGridStateManager stateManager;
  final PlutoColumn column;
  final bool disableFilter;

  PlutoColumnFilter({
    required this.stateManager,
    required this.column,
    this.disableFilter = false,
    Key? key,
  }) : super(key: ValueKey('column_filter_${column.key}'));

  @override
  PlutoColumnFilterState createState() => PlutoColumnFilterState();
}

class PlutoColumnFilterState extends PlutoStateWithChange<PlutoColumnFilter> {
  List<PlutoRow> _filterRows = [];
  String _selectedFilter = '';
  String _text = '';
  bool _enabled = false;
  bool isfilterMenuOpen = false;
  bool isfilterDataMenuOpen = false;
  String columnName = '';
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _textValues = {};
  final Map<String, List<PlutoFilterType>> _columnMultiFilters = {};

  late final ScrollController _scrollController;

  late SharedPreferences _prefs;
  bool _initialized = false;

  // Store filter state - MOVED TO STATIC TO SHARE ACROSS ALL COLUMN INSTANCES
  static final Map<String, Map<String, Set<String>>> _globalActiveFilters = {};
  static final Map<String, List<PlutoRow>> _globalOriginalRows = {};

  late final StreamSubscription _event;
  late final FocusNode _focusNode;
  List<String> _allValues = [];
  Set<String> _selectedValues = {};
  List<PlutoRow> listOfRows = [];
  bool _selectAllChecked = false;
  late PlutoGridStyleConfig style;

  // Store filter states
  String _selectedDropdownValue = '';
  String _searchText = '';

  String get _gridKey => '${widget.stateManager.hashCode}';

  Map<String, Set<String>> get _activeFilters {
    _globalActiveFilters[_gridKey] ??= {};
    return _globalActiveFilters[_gridKey]!;
  }

  List<PlutoRow>? get _originalRows {
    return _globalOriginalRows[_gridKey];
  }

  set _originalRows(List<PlutoRow>? rows) {
    if (rows != null) {
      _globalOriginalRows[_gridKey] = rows;
    }
  }

  @override
  initState() {
    super.initState();
    _initializePrefs();
    _scrollController = ScrollController();

    _selectedFilter = widget.column.type is PlutoColumnTypeText
        ? 'Contains'
        : widget.column.type is PlutoColumnTypeNumber || widget.column.type is PlutoColumnTypeCurrency
        ? 'Equals'
        : 'Contains';

    // Store original rows at grid level
    _initializeOriginalRows();

    final columnField = widget.column.field;

    // Only add filters for columns that exist in this grid
    if (widget.stateManager.refColumns.any((col) => col.field == columnField)) {
      _activeFilters[columnField] = Set<String>();
    }

    _focusNode = FocusNode(onKeyEvent: _handleOnKey);
    widget.column.setFilterFocusNode(_focusNode);
    _event = stateManager.eventManager!.listener(_handleFocusFromRows);

    // Initialize lists with all available values
    _allValues = _getUniqueValuesForColumn();
    listOfRows = widget.stateManager.refRows.toList();
    style = stateManager.style;

    updateState(PlutoNotifierEventForceUpdate.instance);
  }

  void _initializeOriginalRows() {
    if (_originalRows == null || _originalRows!.isEmpty) {
      _originalRows = List.from(widget.stateManager.refRows);
    }
  }

  Future<void> _initializePrefs() async {
    await _loadFilterFromStorage();
    _initialized = true;
  }

  TextEditingController get _controller {
    final columnField = widget.column.field;
    if (!_controllers.containsKey(columnField)) {
      _controllers[columnField] = TextEditingController(text: _getFilterValueForColumn(columnField));
    }
    return _controllers[columnField]!;
  }

  String _getFilterValueForColumn(String columnField) {
    return _textValues[columnField] ?? '';
  }

  Future<void> _loadFilterFromStorage() async {
    if (widget.stateManager?.moduleName == null) return;

    try {
      final GetStorage storage = GetStorage();
      final String projectId = widget.stateManager?.projectId ?? '';
      final String moduleName = widget.stateManager?.moduleName ?? '';
      final String workspace = widget.stateManager?.workspace ?? '';
      final filters = storage.read('filters') ?? {};
      final dispatcher = filters[workspace] ?? {};
      if (dispatcher is! Map) return;

      final resourcePlanning = dispatcher[moduleName] ?? {};
      if (resourcePlanning is! Map) return;

      final projectData = resourcePlanning[projectId] ?? {};
      if (projectData is! Map) return;

      final plutoFilters = projectData['plutoFilters'] ?? {};
      if (plutoFilters is! Map) return;

      final columnField = widget.column.field;
      final columnFilter = plutoFilters[columnField];

      if (columnFilter != null && columnFilter is Map) {
        if (mounted) {
          setState(() {
            final columnField = widget.column.field;
            _selectedDropdownValue = columnFilter['type'] ?? '';
            _selectedFilter = _selectedDropdownValue.isNotEmpty ?
            _selectedDropdownValue : _selectedFilter;

            // Load search text
            _searchText = columnFilter['search'] ?? '';
            _textValues[columnField] = _searchText;
            // Update text controller with search text
            if (_searchText.isNotEmpty) {
              if (_controllers.containsKey(columnField)) {
                _controllers[columnField]!.text = _searchText;
              } else {
                _controllers[columnField] = TextEditingController(text: _searchText);
              }
            }

            // Handle content values for selection
            final contentValues = columnFilter['content'] ?? [];
            if (contentValues is List) {
              _selectedValues.clear();
              for (var value in contentValues) {
                if (value != null) _selectedValues.add(value.toString());
              }
            }

            // Enable filter if there's search text or selected values
            _enabled = _searchText.isNotEmpty || _selectedValues.isNotEmpty;
          });

          // Ensure we wait for widget to be fully mounted before applying filters
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Make sure original rows are captured before filtering
            _initializeOriginalRows();

            // Apply filter - crucial change: adding this to ensure filter is applied on load
            if (_searchText.isNotEmpty) {
              // Update active filters for this column
              _activeFilters[columnField] = {_searchText};

              // Apply the search filter
              _handleOnChanged(_searchText);
            } else if (_selectedValues.isNotEmpty) {
              _activeFilters[columnField] = Set.from(_selectedValues);
              _applyAllFilters();
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading filters from GetStorage: $e');
    }
  }

  Future<void> _saveFilterToStorage() async {
    // Skip saving if no context available
    if (widget.stateManager?.moduleName == null) {
      return;
    }

    try {
      final GetStorage storage = GetStorage();
      final String moduleName = widget.stateManager?.moduleName ?? '';
      final String projectId = widget.stateManager?.projectId ?? '';
      final String columnField = widget.column.field;
      final String workspace = widget.stateManager?.workspace ?? '';

      final filters = storage.read('filters') ?? {};

      // Ensure the dispatcher map exists
      final dispatcher = filters[workspace] ?? {};
      if (dispatcher is! Map) {
        return;
      }

      // Ensure the resourcePlanning map exists
      Map resourcePlanning = dispatcher[moduleName] ?? {};

      // Ensure the projectId map exists
      Map projectData = resourcePlanning[projectId] ?? {};

      // Ensure the plutoFilters map exists
      Map plutoFilters = projectData['plutoFilters'] ?? {};

      // Create or update the filter data for this column
      List<String> contentValues = [];

      // Add selected values if they exist (no longer adding search text here)
      if (_selectedValues.isNotEmpty) {
        contentValues.addAll(_selectedValues.toList());
      }

      // Only save if we have filter data
      if (_selectedDropdownValue.isNotEmpty || contentValues.isNotEmpty || _searchText.isNotEmpty) {
        plutoFilters[columnField] = {
          'type': _selectedDropdownValue,
          'content': contentValues,
          'search': _searchText  // Added separate search field
        };
      } else {
        // Remove the filter if empty
        plutoFilters.remove(columnField);
      }

      // Update the nested structure
      projectData['plutoFilters'] = plutoFilters;
      resourcePlanning[projectId] = projectData;
      dispatcher[moduleName] = resourcePlanning;
      filters[workspace] = dispatcher;

      // Save the updated structure to 'filters'
      await storage.write('filters', filters);
    } catch (e) {
      debugPrint('Error saving filter to GetStorage: $e');
    }
  }

  // NEW METHOD: Apply all filters from all columns
  void _applyAllFilters() {
    _initializeOriginalRows();

    // Start with original rows
    List<PlutoRow> filteredRows = List.from(_originalRows ?? []);

    // Apply all active filters from all columns
    _activeFilters.forEach((field, values) {
      if (values.isNotEmpty) {
        filteredRows = _applyColumnFilter(filteredRows, field, values);
      }
    });

    // Update grid
    widget.stateManager.refRows.clear();
    widget.stateManager.refRows.addAll(filteredRows);
    widget.stateManager.notifyListeners();
    _saveFilterToStorage();
  }

  // NEW METHOD: Apply filter for a specific column
  List<PlutoRow> _applyColumnFilter(List<PlutoRow> rows, String field, Set<String> filterValues) {
    return rows.where((row) {
      dynamic cellValue = row.cells[field]?.value;

      // Handle currency values
      if (widget.stateManager.columns.any((col) => col.field == field && col.type is PlutoColumnTypeCurrency)) {
        if (cellValue is String) {
          cellValue = double.tryParse(cellValue.replaceAll(RegExp(r'[^0-9.]'), ''))?.toString();
        }
        cellValue = formatNumber(cellValue is String ? double.tryParse(cellValue) : cellValue);
      } else {
        cellValue = cellValue?.toString() ?? '';
        if (cellValue == 'Checked') cellValue = 'true';
        if (cellValue == 'Unchecked') cellValue = 'false';
      }

      // Check if this is a search filter (single value) or selection filter (multiple values)
      if (filterValues.length == 1) {
        String filterValue = filterValues.first;

        // Get filter type for this column - default to Contains for text search
        String filterType = field == widget.column.field ? _selectedFilter : 'Contains';

        // Apply search-based filtering
        return _matchesSearchCriteria(cellValue.toString(), filterValue, filterType, field);
      } else {
        // Apply selection-based filtering
        return filterValues.contains(cellValue);
      }
    }).toList();
  }

  bool _matchesSearchCriteria(String cellValue, String filterValue, String filterType, String field) {
    // Handle numeric filters
    if (widget.stateManager.columns.any((col) => col.field == field &&
        (col.type is PlutoColumnTypeNumber || col.type is PlutoColumnTypeCurrency)) &&
        (filterType == 'Greater Than' || filterType == 'Less Than' || filterType == 'Equals')) {

      final num? numValue = num.tryParse(cellValue);
      final num? numFilterValue = num.tryParse(filterValue);

      if (numValue != null && numFilterValue != null) {
        switch (filterType) {
          case 'Greater Than': return numValue > numFilterValue;
          case 'Less Than': return numValue < numFilterValue;
          case 'Equals': return numValue == numFilterValue;
          default: return false;
        }
      }
      return false;
    } else {
      // Text-based filtering
      String cellText = cellValue.toLowerCase();
      String searchText = filterValue.toLowerCase();

      switch (filterType) {
        case 'Equals': return cellText == searchText;
        case 'Does Not Equal': return cellText != searchText;
        case 'Contains': return cellText.contains(searchText);
        case 'Does Not Contain': return !cellText.contains(searchText);
        case 'Starts With': return cellText.startsWith(searchText);
        case 'Ends With': return cellText.endsWith(searchText);
        default: return cellText.contains(searchText);
      }
    }
  }

  void _resetFilter({bool fromEvent = false}) {
    if (!mounted) return;

    setState(() {
      // Clear filter state for this column
      _selectedValues.clear();
      final columnField = widget.column.field;
      if (_controllers.containsKey(columnField)) {
        _controllers[columnField]!.clear();
      }
      _textValues[columnField] = '';
      _searchText = '';
      _selectedDropdownValue = '';

      // Remove this column's filter
      _activeFilters.remove(columnField);
    });

    // Apply remaining filters
    if (!fromEvent) {
      _applyAllFilters();
    }
  }

  void _handleOnChanged(String changed) {
    if (mounted) {
      setState(() {
        final columnField = widget.column.field;

        // Ensure we have the original rows stored
        _initializeOriginalRows();

        // Update search text for storage
        _searchText = changed;
        _textValues[columnField] = changed;

        // Update the active filters for this column
        if (changed.isEmpty) {
          // Remove search filter for this column, but keep selection filters
          _activeFilters[columnField]?.clear();
          if (_selectedValues.isEmpty) {
            _activeFilters.remove(columnField);
          } else {
            _activeFilters[columnField] = Set.from(_selectedValues);
          }
        } else {
          // Add search filter (this will override selection for this column)
          _activeFilters[columnField] = {changed};
          // Update selected filter type if not already set
          if (_selectedDropdownValue.isEmpty) {
            _selectedDropdownValue = _selectedFilter;
          }
        }
      });

      // Apply all filters
      _applyAllFilters();
    }
  }

  void _handleValueSelection(String value, bool? selected) {
    if (!mounted || selected == null) return;

    final columnField = widget.column.field;

    setState(() {
      if (selected) {
        if (widget.column.type is PlutoColumnTypeCurrency) {
          _selectedValues.add(value);
        } else {
          if (value == "Checked") {
            _selectedValues.add('true');
          } else if (value == "Unchecked") {
            _selectedValues.add('false');
          } else {
            _selectedValues.add(value);
          }
        }
      } else {
        if (widget.column.type is PlutoColumnTypeCurrency) {
          _selectedValues.remove(value);
        } else {
          if (value == "Checked") {
            _selectedValues.remove('true');
          } else if (value == "Unchecked") {
            _selectedValues.remove('false');
          } else {
            _selectedValues.remove(value);
          }
        }
      }

      // Update select all checkbox state
      _selectAllChecked = _selectedValues.length == _allValues.length;

      // Update active filters - clear search text when using selections
      if (_selectedValues.isNotEmpty) {
        _searchText = '';
        _textValues[columnField] = '';
        if (_controllers.containsKey(columnField)) {
          _controllers[columnField]!.clear();
        }
        _activeFilters[columnField] = Set.from(_selectedValues);
      } else {
        _activeFilters.remove(columnField);
      }
    });

    // Apply all filters
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _applyAllFilters();
      }
    });
  }

  void _handleSelectAllValues(bool selected) {
    setState(() {
      final columnField = widget.column.field;

      if (selected) {
        _selectedValues.addAll(_allValues);
        _selectAllChecked = true;
      } else {
        _selectedValues.clear();
        _selectAllChecked = false;
      }

      // Clear search text when using selections
      if (_selectedValues.isNotEmpty) {
        _searchText = '';
        _textValues[columnField] = '';
        if (_controllers.containsKey(columnField)) {
          _controllers[columnField]!.clear();
        }
        _activeFilters[columnField] = Set.from(_selectedValues);
      } else {
        _activeFilters.remove(columnField);
      }
    });

    // Apply all filters
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _applyAllFilters();
      }
    });
  }

  String getCurrentLocale() {
    // Get locale from PlutoGrid widget
    final context = widget.stateManager.gridFocusNode.context;
    if (context == null) return 'en';

    final plutoGrid = context.findAncestorWidgetOfExactType<PlutoGrid>();
    return plutoGrid?.locale ?? 'en';
  }

  String formatNumber(double? number, {String? locale, int decimalPlaces = 2}) {
    if (number == null) return '0.${'0' * decimalPlaces}';

    try {
      // Create a dynamic format pattern based on the decimalPlaces
      final pattern = '#,##0.${'0' * decimalPlaces}';
      final formatter = NumberFormat(pattern, getCurrentLocale());
      return formatter.format(number);
    } catch (e) {
      print('Error formatting number: $e - $number');
      return number.toStringAsFixed(decimalPlaces);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _event.cancel();

    // Dispose all text controllers
    for (var controller in _controllers.values) {
      controller.dispose();
    }

    _focusNode.dispose();
    super.dispose();
  }

  String get _filterValue {
    return _filterRows.isEmpty ? '' : _filterRows.first.cells[FilterHelper.filterFieldValue]!.value.toString();
  }

  bool get _hasCompositeFilter {
    return _filterRows.length > 1 || stateManager
        .filterRowsByField(FilterHelper.filterFieldAllColumns)
        .isNotEmpty;
  }

  InputBorder get _border =>
      const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.transparent, width: 0.0),
        borderRadius: BorderRadius.zero,
      );

  InputBorder get _enabledBorder =>
      const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.transparent, width: 0.0),
        borderRadius: BorderRadius.zero,
      );

  InputBorder get _disabledBorder =>
      const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.transparent, width: 0.0),
        borderRadius: BorderRadius.zero,
      );

  InputBorder get _focusedBorder =>
      const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.transparent, width: 0.0),
        borderRadius: BorderRadius.zero,
      );

  Color get _textFieldColor => _enabled ? stateManager.configuration.style.cellColorInEditState : stateManager.configuration.style.cellColorInReadOnlyState;

  EdgeInsets get _padding => widget.column.filterPadding ?? stateManager.configuration.style.defaultColumnFilterPadding;

  Color get _colorFilter => widget.column.colorFilter ?? const Color(0xFFF8F8F8);

  bool? get _disabledFilter => widget.column.disabledFilter;

  @override
  PlutoGridStateManager get stateManager => widget.stateManager;

  @override
  void updateState(PlutoNotifierEvent event) {
    _filterRows = update<List<PlutoRow>>(
      _filterRows,
      stateManager.filterRowsByField(widget.column.field),
      compare: listEquals,
    );
    if (_focusNode.hasPrimaryFocus != true) {
      _text = update<String>(_text, _filterValue);
      if (changed) {
        _controller.text = _text;
      }
    }
    _enabled = update<bool>(
      _enabled,
      widget.column.enableFilterMenuItem && !_hasCompositeFilter,
    );
  }

  void _moveDown({required bool focusToPreviousCell}) {
    if (!focusToPreviousCell || stateManager.currentCell == null) {
      stateManager.setCurrentCell(
        stateManager.refRows.first.cells[widget.column.field],
        0,
        notify: false,
      );
      stateManager.scrollByDirection(PlutoMoveDirection.down, 0);
    }
    stateManager.setKeepFocus(true, notify: false);
    stateManager.gridFocusNode.requestFocus();
    stateManager.notifyListeners();
  }

  KeyEventResult _handleOnKey(FocusNode node, KeyEvent event) {
    var keyManager = PlutoKeyManagerEvent(
      focusNode: node,
      event: event as RawKeyEvent, // Simple cast instead of conversion
    );
    if (keyManager.isKeyUpEvent) {
      return KeyEventResult.handled;
    }
    final handleMoveDown = (keyManager.isDown || keyManager.isEnter || keyManager.isEsc) && stateManager.refRows.isNotEmpty;
    final handleMoveHorizontal = keyManager.isTab || (_controller.text.isEmpty && keyManager.isHorizontal);
    final skip = !(handleMoveDown || handleMoveHorizontal || keyManager.isF3);
    if (skip) {
      if (keyManager.isUp) {
        return KeyEventResult.handled;
      }
      return stateManager.keyManager!.eventResult.skip(
        KeyEventResult.ignored,
      );
    }
    if (handleMoveDown) {
      _moveDown(focusToPreviousCell: keyManager.isEsc);
    } else if (handleMoveHorizontal) {
      stateManager.nextFocusOfColumnFilter(
        widget.column,
        reversed: keyManager.isLeft || keyManager.isShiftPressed,
      );
    } else if (keyManager.isF3) {
      stateManager.showFilterPopup(
        _focusNode.context!,
        calledColumn: widget.column,
        onClosed: () {
          stateManager.setKeepFocus(true, notify: false);
          _focusNode.requestFocus();
        },
      );
    }
    return KeyEventResult.handled;
  }

  void _handleFocusFromRows(PlutoGridEvent plutoEvent) {
    if (!_enabled) {
      return;
    }
    if (plutoEvent is PlutoGridCannotMoveCurrentCellEvent && plutoEvent.direction.isUp) {
      var isCurrentColumn = widget.stateManager.refColumns[stateManager.columnIndexesByShowFrozen[plutoEvent.cellPosition.columnIdx!]].key == widget.column.key;
      if (isCurrentColumn) {
        stateManager.clearCurrentCell(notify: false);
        stateManager.setKeepFocus(false);
        _focusNode.requestFocus();
      }
    }
    if (plutoEvent is PlutoGridResetAllFiltersEvent) {
      _resetFilter(fromEvent: true);
    }
  }

  void _handleOnTap() {
    stateManager.setKeepFocus(false);
  }

  void _handleOnEditingComplete() {
    // empty for ignore event of OnEditingComplete.
  }

  Widget _buildFilterIcon({String? filterType}) {
    String selectedValue = filterType ?? _selectedFilter;
    switch (selectedValue) {
      case 'Equals':
        return Image.memory(
          base64Decode(equalsIcon),
          width: 24,
          height: 12,
          fit: BoxFit.contain,
        );
      case 'Does Not Equal':
        return Image.memory(
          base64Decode(notEqualIcon),
          width: 24,
          height: 12,
          fit: BoxFit.contain,
        );
      case 'Contains':
        return Image.memory(
          base64Decode(containIcon),
          width: 24,
          height: 12,
          fit: BoxFit.contain,
        );
      case 'Does Not Contain':
        return Image.memory(
          base64Decode(notContainIcon),
          width: 24,
          height: 12,
          fit: BoxFit.contain,
        );
      case 'Begins With':
        return Image.memory(
          base64Decode(beginsWithIcon),
          width: 24,
          height: 12,
          fit: BoxFit.contain,
        );
      case 'Ends With':
        return Image.memory(
          base64Decode(endWithIcon),
          width: 24,
          height: 12,
          fit: BoxFit.contain,
        );
      case 'Greater Than':
        return SvgPicture.string(
          greaterThanIcon,
          width: 24,
          height: 12,
          fit: BoxFit.contain,
        );
      case 'Less Than':
        return SvgPicture.string(
          lessThanIcon,
          width: 24,
          height: 12,
          fit: BoxFit.contain,
        );
      default:
        return const Icon(
          Icons.delete_forever,
          color: Color(0xFF4F4F4F),
        );
    }
  }

  List<String> _getUniqueValuesForColumn() {
    final columnField = widget.column.field;
    final Set<String> uniqueValues = {};

    void addValue(dynamic value) {
      if (value != null) {
        if (widget.column.type is PlutoColumnTypeCurrency) {
          try {
            final formattedValue = formatNumber(
              value is String ? double.tryParse(value.replaceAll(RegExp(r'[^\d.]'), '')) ?? 0.0 : value,
            );
            uniqueValues.add(formattedValue.toString());
          } catch (e) {
            print('Error formatting currency value: $e');
            uniqueValues.add(value.toString());
          }
        } else {
          if (value == true) {
            uniqueValues.add('Checked');
          } else if (value == false) {
            uniqueValues.add('Unchecked');
          } else {
            uniqueValues.add(value.toString());
          }
        }
      }
    }

    for (var row in widget.stateManager.rows) {
      // Add group row value
      addValue(row.cells[columnField]?.value);

      // Add child row values
      if (row.type.isGroup) {
        for (var child in row.type.group.children) {
          addValue(child.cells[columnField]?.value);
        }
      }
    }

    return uniqueValues.toList()
      ..sort();
  }

  bool _matchesFilterCriteria(String value, String filter) {
    // Normalize strings by removing extra spaces and converting to lowercase for comparison
    String normalizedValue = value.trim().toLowerCase();
    String normalizedFilter = filter.trim().toLowerCase();

    // Split the filter into words for partial matching
    List<String> filterWords = normalizedFilter.split(RegExp(r'\s+'));

    switch (_selectedFilter) {
      case 'Contains':
      // Check if all filter words are present in the value in any order
        return filterWords.every((word) => normalizedValue.contains(word));
      case 'Equals':
        return normalizedValue == normalizedFilter;
      case 'Does Not Equal':
        return normalizedValue != normalizedFilter;
      case 'Starts With':
        return normalizedValue.startsWith(normalizedFilter);
      case 'Ends With':
        return normalizedValue.endsWith(normalizedFilter);
      case 'Greater Than':
        final num? numValue = num.tryParse(value);
        final num? filterValue = num.tryParse(filter);
        return numValue != null && filterValue != null && numValue > filterValue;
      case 'Less Than':
        final num? numValue = num.tryParse(value);
        final num? filterValue = num.tryParse(filter);
        return numValue != null && filterValue != null && numValue < filterValue;
      default:
      // Default to partial matching for better search results
        return filterWords.every((word) => normalizedValue.contains(word));
    }
  }
  PlutoFilterType _resolveFilterType() {
    switch (_selectedFilter) {
      case 'Equals':
        return const PlutoFilterTypeEquals();
      case 'Does Not Equal':
        return const PlutoFilterTypeDoesNotEquals();
      case 'Does Not Contain':
        return const PlutoFilterTypeNotContains();
      case 'Begins With':
        return const PlutoFilterTypeStartsWith();
      case 'Ends With':
        return const PlutoFilterTypeEndsWith();
      case 'Greater Than':
        return const PlutoFilterTypeGreaterThan();
      case 'Less Than':
        return const PlutoFilterTypeLessThan();
      default:
        return const PlutoFilterTypeContains();
    }
  }

  @override
  Widget build(BuildContext context) {
    return OnHover(
      builder: (isHovered) =>
          SizedBox(
            height: stateManager.columnFilterHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.stateManager.rows.isNotEmpty && widget.column.backgroundColor != null && widget.column.isAllColumnColored
                    ? Color.alphaBlend(widget.column.backgroundColor!.withOpacity(0.6), _colorFilter)
                    : _colorFilter,
                border: BorderDirectional(
                  top: BorderSide(color: style.borderColor),
                  end: style.enableColumnBorderVertical ? BorderSide(color: style.borderColor) : BorderSide.none,
                ),
              ),
              child: _disabledFilter != null || widget.disableFilter
                  ? const SizedBox()
                  : Padding(
                padding: _padding,
                child: Align(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      SizedBox(
                        width: 20,
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            scrollbarTheme: const ScrollbarThemeData().copyWith(
                              thumbColor: WidgetStateProperty.all(const Color(0xFF959595)),
                              thickness: WidgetStateProperty.all(3),
                              trackColor: WidgetStateProperty.all(const Color(0xFFE9E9E9)),
                            ),
                            hoverColor: Colors.transparent,
                          ),
                          child: StatefulBuilder(
                            builder: (_, setState) =>
                                DropdownButtonHideUnderline(
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton2<String>(
                                      dropdownStyleData: DropdownStyleData(
                                        elevation: 4,
                                        scrollPadding: const EdgeInsets.all(5).copyWith(right: 10),
                                        maxHeight: 300,
                                        width: 200,
                                        padding: EdgeInsets.zero,
                                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: Colors.white),
                                        scrollbarTheme: const ScrollbarThemeData(
                                          radius: Radius.circular(1.5),
                                          thickness: WidgetStatePropertyAll(3),
                                          thumbVisibility: WidgetStatePropertyAll(true),
                                        ),
                                      ),
                                      isExpanded: true,
                                      isDense: true,
                                      onMenuStateChange: (isOpen) => setState(() => isfilterMenuOpen = isOpen),
                                      // TODO add hovering effect and selected color
                                      items: (widget.column.type is PlutoColumnTypeNumber ? filteringTypesNumber : filteringTypes)
                                          .map(
                                            (String value) =>
                                            DropdownMenuItem(
                                              value: value,
                                              child: Column(
                                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                mainAxisSize: MainAxisSize.max,
                                                children: [
                                                  if (value == 'Clear All Filters') ...[
                                                    Container(
                                                      alignment: Alignment.topCenter,
                                                      color: const Color(0xFFE9E9E9),
                                                      height: 1,
                                                    ),
                                                    const SizedBox(height: 5),
                                                  ],
                                                  OnHover(
                                                    builder: (isHovered) =>
                                                        Container(
                                                          decoration: BoxDecoration(
                                                            color: isHovered ? const Color(0xffACC7DB) : Colors.transparent,
                                                            borderRadius: BorderRadius.circular(6),
                                                          ),
                                                          alignment: Alignment.center,
                                                          width: double.infinity,
                                                          height: 40,
                                                          child: Row(
                                                            children: [
                                                              SizedBox(
                                                                width: 40,
                                                                child: Align(
                                                                  alignment: Alignment.center,
                                                                  child: _buildFilterIcon(filterType: value),
                                                                ),
                                                              ),
                                                              Text(
                                                                value,
                                                                style: style.cellTextStyle.copyWith(fontSize: 11),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                      )
                                          .toList(),
                                      onChanged: (String? value) {
                                        setState(() {
                                          if (value?.toLowerCase().contains('clear') ?? false) {
                                            _resetFilter();
                                          } else {
                                            _selectedFilter = value ?? '';
                                            if (_controller.text.isNotEmpty) {
                                              _handleOnChanged(_controller.text);
                                            }
                                          }
                                        });
                                      },
                                      iconStyleData: const IconStyleData(icon: SizedBox()),
                                      hint: _selectedFilter.isEmpty
                                          ? SvgPicture.string(
                                        filterIcon,
                                        width: 24,
                                        height: 12,
                                        fit: BoxFit.contain,
                                        // Fix: Replace colorFilter with color
                                        color: isfilterMenuOpen ? const Color(0xff045692) : const Color(0xFFC7C7C7),
                                      )
                                          : _buildFilterIcon(),
                                      menuItemStyleData: const MenuItemStyleData(padding: EdgeInsets.zero),
                                    ),
                                  ),
                                ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          child: _selectedFilter.isNotEmpty
                              ? TextField(
                            focusNode: _focusNode,
                            controller: _controller,
                            enabled: _enabled,
                            style: style.cellTextStyle,
                            onTap: _handleOnTap,
                            onChanged: _handleOnChanged,
                            onEditingComplete: _handleOnEditingComplete,
                            decoration: InputDecoration(
                              hintText: _enabled
                                  ? _selectedFilter
                                  : '',
                              hintStyle: style.cellTextStyle.copyWith(color: const Color(0xFFC7C7C7), fontSize: 11),
                              filled: false,
                              fillColor: _textFieldColor,
                              border: _border,
                              enabledBorder: _enabledBorder,
                              disabledBorder: _disabledBorder,
                              focusedBorder: _focusedBorder,
                              contentPadding: const EdgeInsets.only(bottom: 10),
                            ),
                          )
                              : const SizedBox(),
                        ),
                      ),

                      GestureDetector(
                        onTap: () {
                          final RenderBox button = context.findRenderObject() as RenderBox;
                          final overlay = Overlay.of(context);
                          _allValues = _getUniqueValuesForColumn();

                          if (overlay != null) {
                            final RenderBox overlayBox = overlay.context.findRenderObject() as RenderBox;
                            final Offset offset = button.localToGlobal(Offset.zero, ancestor: overlayBox);

                            showDialog(
                              context: context,
                              barrierDismissible: true,
                              barrierColor: Colors.transparent,
                              builder: (BuildContext context) {
                                return Stack(
                                  children: [
                                    // Invisible barrier that closes dialog
                                    Positioned.fill(
                                      child: GestureDetector(
                                        onTap: () => Navigator.pop(context),
                                        child: Container(color: Colors.transparent),
                                      ),
                                    ),
                                    // Positioned dialog
                                    Positioned(
                                      left: offset.dx,
                                      top: offset.dy + button.size.height,
                                      child: Material(
                                        color: Colors.transparent,
                                        child: StatefulBuilder(
                                          builder: (context, setDialogState) {
                                            return GestureDetector(
                                              onTap: () {}, // Prevent dialog from closing when clicking inside
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                width: 280,
                                                constraints: const BoxConstraints(maxHeight: 360),
                                                decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  borderRadius: BorderRadius.circular(6),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black.withOpacity(0.05),
                                                      blurRadius: 10,
                                                      offset: const Offset(0, 3),
                                                    ),
                                                  ],
                                                ),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Row(
                                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Icon(
                                                              Icons.filter_list,
                                                              size: 14,
                                                              color: const Color(0xff045692),
                                                            ),
                                                            SizedBox(width: 4),
                                                            Text(
                                                              'Filter ${widget.column.title}',
                                                              style: style.cellTextStyle.copyWith(
                                                                fontSize: 11,
                                                                color: const Color(0xff045692),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        IconButton(
                                                          padding: EdgeInsets.zero,
                                                          constraints: BoxConstraints(),
                                                          icon: Icon(Icons.close, size: 14),
                                                          onPressed: () => Navigator.pop(context),
                                                          color: Colors.grey[400],
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Container(
                                                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                      child: CheckboxListTile(
                                                        shape: RoundedRectangleBorder(
                                                          borderRadius: BorderRadius.circular(3),
                                                        ),
                                                        visualDensity: VisualDensity(horizontal: -4, vertical: -4),
                                                        contentPadding: EdgeInsets.zero,
                                                        checkColor: Colors.white,
                                                        activeColor: const Color(0xff045692),
                                                        side: BorderSide(color: Colors.grey[300]!),
                                                        value: _selectAllChecked,
                                                        onChanged: (value) {
                                                          setDialogState(() {
                                                            _selectAllChecked = value!;
                                                            _handleSelectAllValues(value);
                                                          });
                                                        },
                                                        title: Text(
                                                          'Select All',
                                                          style: style.cellTextStyle.copyWith(
                                                            fontSize: 11,
                                                            color: Colors.grey[600],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    Divider(
                                                      height: 1,
                                                      thickness: 1,
                                                      color: Colors.grey[200],
                                                      indent: 2,
                                                      endIndent: 2,
                                                    ),
                                                    const SizedBox(height: 1),

                                                    Flexible(
                                                      child: Container(
                                                        decoration: BoxDecoration(
                                                          borderRadius: BorderRadius.circular(4),
                                                        ),
                                                        child: Theme(
                                                          data: Theme.of(context).copyWith(
                                                            scrollbarTheme: ScrollbarThemeData(
                                                              thumbVisibility: WidgetStateProperty.all(true),
                                                              thickness: WidgetStateProperty.all(3.0),
                                                              radius: Radius.circular(3),
                                                              thumbColor: WidgetStateProperty.all(Colors.grey[400]),
                                                            ),
                                                          ),
                                                          child: Scrollbar(
                                                            controller: _scrollController,
                                                            child: ListView.builder(
                                                              controller: _scrollController,
                                                              padding: EdgeInsets.symmetric(horizontal: 2, vertical: 0),
                                                              itemCount: _allValues.length,
                                                              itemBuilder: (context, index) {
                                                                final value = _allValues[index];
                                                                return Container(
                                                                  constraints: BoxConstraints(minHeight: 24),
                                                                  margin: EdgeInsets.symmetric(vertical: 2),
                                                                  child: Material(
                                                                    color: Colors.transparent,
                                                                    child: InkWell(
                                                                      onTap: () {
                                                                        final isSelected = _selectedValues.contains(value == "Checked" ? "true" : value == "Unchecked" ? "false" : value);
                                                                        setDialogState(() {
                                                                          _handleValueSelection(value, !isSelected);
                                                                        });
                                                                      },
                                                                      child: Row(
                                                                        crossAxisAlignment: CrossAxisAlignment.center,
                                                                        children: [
                                                                          Expanded(
                                                                            child: Padding(
                                                                              padding: EdgeInsets.symmetric(vertical: 2, horizontal: 8),
                                                                              child: Text(
                                                                                value,
                                                                                style: style.cellTextStyle.copyWith(
                                                                                  fontSize: 11,
                                                                                  color: Colors.grey[700],
                                                                                ),
                                                                                softWrap: true,
                                                                              ),
                                                                            ),
                                                                          ),
                                                                          SizedBox(width: 4),
                                                                          Transform.translate(
                                                                            offset: Offset(-2, 0),
                                                                            child: SizedBox(
                                                                              width: 24,
                                                                              height: 24,
                                                                              child: Checkbox(
                                                                                shape: RoundedRectangleBorder(
                                                                                  borderRadius: BorderRadius.circular(3),
                                                                                ),
                                                                                visualDensity: VisualDensity(horizontal: -4, vertical: -4),
                                                                                checkColor: Colors.white,
                                                                                activeColor: const Color(0xff045692),
                                                                                side: BorderSide(color: Colors.grey[300]!),
                                                                                value: _selectedValues.contains(value == "Checked" ? "true" : value == "Unchecked" ? "false" : value),
                                                                                onChanged: (selected) {
                                                                                  setDialogState(() {
                                                                                    _handleValueSelection(value, selected);
                                                                                  });
                                                                                },
                                                                              ),
                                                                            ),
                                                                          ),
                                                                          SizedBox(width: 4),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                );
                                                              },
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 6),
                                                    Align(
                                                      alignment: Alignment.centerRight,
                                                      child: ElevatedButton.icon(
                                                        onPressed: () {
                                                          _resetFilter();
                                                          Navigator.pop(context);
                                                        },
                                                        icon: Icon(Icons.refresh, size: 12),
                                                        label: Text(
                                                          'Reset Filter',
                                                          style: style.cellTextStyle.copyWith(
                                                            fontSize: 11,
                                                            color: Colors.white,
                                                          ),
                                                        ),
                                                        style: ElevatedButton.styleFrom(
                                                          backgroundColor: const Color(0xff045692),
                                                          foregroundColor: Colors.white,
                                                          elevation: 0,
                                                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                          shape: RoundedRectangleBorder(
                                                            borderRadius: BorderRadius.circular(3),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            );
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5.0, horizontal: 5.0),
                          child: Icon(
                            Icons.arrow_drop_down,
                            color: Colors.grey[600],
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
    );
  }
}

List<String> filteringTypes = [
  'Equals',
  'Does Not Equal',
  'Contains',
  'Does Not Contain',
  'Begins With',
  'Ends With',
  'Greater Than',
  'Less Than',
  'Clear All Filters',
];

List<String> filteringTypesNumber = [
  'Equals',
  'Does Not Equal',
  'Greater Than',
  'Less Than',
  'Clear All Filters',
];
const String filterIcon = '''<svg width="9" height="10" viewBox="0 0 9 10" fill="none" xmlns="http://www.w3.org/2000/svg">
<path d="M3.27891 4.753C3.37034 4.85575 3.42053 4.98998 3.42053 5.12884V9.22047C3.42053 9.46671 3.70826 9.59168 3.87857 9.41857L4.98377 8.11054C5.13167 7.92725 5.21323 7.83652 5.21323 7.65509V5.12976C5.21323 4.99091 5.26433 4.85668 5.35486 4.75391L8.52614 1.20013C8.76367 0.933526 8.58082 0.501221 8.22944 0.501221H0.404303C0.0529335 0.501221 -0.130818 0.932601 0.107611 1.20013L3.27891 4.753Z" fill="#C7C7C7"/>
</svg>''';
const String downArrowIcon = '''<svg width="9" height="10" viewBox="0 0 12 7" fill="none" xmlns="http://www.w3.org/2000/svg">
<path d="M1 1L6 6L11 1" stroke="#C7C7C7" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>''';

const String containIcon =
'''iVBORw0KGgoAAAANSUhEUgAAABgAAAANCAYAAACzbK7QAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAI0SURBVHgBvdJLaBNBGAfw/27avKQPk+CrBl99aYu0VTR6EEH0pB4EEQ9qb4V6UEHRk1REEaoiCPUgaDz3ICgoioIePWjQWhBBjWlEsSlJyGvL7mb9z3Y2rNCGnvrBL1nmm51v9ptRUCeuJS4NVqtYv1DeVBEf6b+RrLMEGuolLeCUomLvQnkP8IZ/SSyywBo6RD/opTPY0bIZTY1NtUkVo4KpUhJFveAM+Wgn7SOdntGH+QocpntUpi5Ki8G+0HZ0tmyBZmpQFQVe1YeZ2QziX8dQMStiynU6Rzky6CpdoJsiqboKHKfvFKSDrnEuOI1bE1cw+mkET1LjCPsiiPhXIPF0opPpszROIVpFz+mifK4ViNJuuktf6Ki7gN8TxNbQAG1Dz/I+FPQ8Mtpf/Eyk98g1xuTUKh0RnaU/7haJ9hTpFa2kM7TOKeBjWwYiMShim74wW6PZrdI1PSSnZFz70aT/zuCY2Cjdp1YK0AFnUl7P2j0XsTrYhpPtQ+hu7YE34J2WU9bSpHzeRTvoARVUORCj1/SOXtA30SbLsjfNHwVty6K29uZuNKiNKBsl9O7vEv0uy56Li9FLD2mISs4XiMPllccwpeQusnQ+/fmXho2iLREMdgzbCaOqI8VrOpn9iE2xDaLPp2kUc2cnYopOyPOwC1ym267FRdyhR+Fo6DFvTSTgCdQSpmWiaBS5I8sZisuv7sfcNX1PM+4zyEnuyAuBZv/bWVPLEeYLFabz3m9p6eMfWJqqCa8PjDQAAAAASUVORK5CYII=''';
const String equalsIcon =
'''iVBORw0KGgoAAAANSUhEUgAAAAwAAAANCAYAAACdKY9CAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAClSURBVHgBlZDBEYIwEEV3V7xTgiVYgkWIXqmAgQrQCoKxATk6WIQlWIIl5K7mu+HEiYR3Smben/27TIocbS1ATjMA/P4N1Y2zgzX6rymNThbIgTIEXKoNdcUznVMDTOg5PLK92UVlJvcZmhctZZywLswWoDwmfx/NU896bXWdEyWgtRoBoaREtEUr2ilaZUIuGuuTdeAyLr0qbMmMzZzrmZ2/V90fXHQx5pC3g8cAAAAASUVORK5CYII=''';
const String notEqualIcon =
'''iVBORw0KGgoAAAANSUhEUgAAAAwAAAAPCAYAAADQ4S5JAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAGESURBVHgBhVI9TMJAFH69HomaEIFoSFzAQPyZZNHFhUgMq4PAyqIjbRMHN2R0KtRRE2FUGJxMGEhYjAOD3ZQEgoyIIQwGEml73jWhaQqRN9y7+9733r373gEsMJnnT2SA4PSM2YJSiogI8TjJybdKgO+8pr88Gyp/fFnQy5kixklFBgIiADdTfavXNH1t+yjCcXBPuXuInsV5rYT6LfCNBjBY8UIjcDCF0yxhOC8h/l41fXU3bmGEcpHBQc5J9tLK4e82jF3L0F4PWzgHpISNh0wencqqPeH85S5LXVTj+KfB0moBDB3oG4aTsqTOvJRJyGPcYXtd0zYlgE973JTVlZAjhIAp6+g5J7h/f6Dn9tevYxdBbJuBVpHqVNabLAFyxVRlvWOim8Hbw7MoID5qr+5KKRKi5PQUCPfbsDwZQ2stROX0ObsF2kUW0cKe/6R0mAfRtBLb7Xcb1qDsUjquKGCtLIh8QlFjzZpAociHf6dII10n1+C4ofEo5C2Aycl+JiywP/D7hUO6Gm4BAAAAAElFTkSuQmCC''';
const String notContainIcon =
'''iVBORw0KGgoAAAANSUhEUgAAABgAAAANCAYAAACzbK7QAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAI6SURBVHgBvdPdS5NRHAfw7/O40jV1c2JZpI6oWC/0QuZLoG1J3lgRUohXCV3UXV0UdRf9Ad0UhBRUF911EQQ1CCGlhAWmIQRC4lZQ0TZtb27pHp/T91nnjCfK0ZUHPuzsvP3O+Z3zaChTxg/7h0wNvtX6DR2PguGZaJkl4CjXKXSc0wQCq042MMqfKP4zwBY6SRF6qRq93cewvr6hNMjIpJB+P4nlREw1VVI79VCBXtDkv4JdtDZNi7TVanjT7n81PzYirFLIpIWxmC3Wc58i4m1Pm3jd6g9w2C0yaYFico0ralHdFmCQ5mgDnbBHzkXnwAURDrbi483rcDb74Ny2HaFEaie7L9MT67DUSCG6JuulFDXREbpKF+gsDasA69xubOw7DWgaGnr7sBz7jlxkFtPZfLfc5F051DpJP1VR0h7gFGVphDbRJWpRASpc1WjsHygGcDb5eA9pVDhdWDJNrxySsB34pwR7gAEZ9T55yEm9pRlfv2D6/GCx7vLvwb57j+ENHoczPBWXQ6w7+yDrndRGDyjjkA0d+P1yZlVWrDQJAc36o+k6avbuL3bUdXZBr6yCkfyBQF1N6Fk8eUbmPCrnPZSpuqM2eJuWqNl2zBtW9OHdLXH1ilRZyedFampCjHfsUq9oiKyTCOkzHVULaTIlHvz5wbitzT4/tONpvcdzoKK6ttQhCgUUFhIQpkkIdk3MjLJ5Mx0kg97RPGx3kJTsJWWp1R1jRjaTJPxVuDVdW1HzvklrX34B1mLMDIqcmR8AAAAASUVORK5CYII=''';
const String beginsWithIcon =
'''iVBORw0KGgoAAAANSUhEUgAAABgAAAANCAYAAACzbK7QAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAIWSURBVHgBvdNfSFNxFAfw7/Ruq2uaU6MJIihuEUGRQtswgooiilVUiD0E+RAGEhoRPSYEvdRLhIEP5Uv0UO/2kJFQD/VQYERJQZmzsrX0anO065/5/e13Ni8K80HwwIft7vzuOb977m8uo+VONwrE3OPOgvnVwgBc11dZ0421NdBR7StBtKkO3+JTePY+5lxzXKUd15P0in7KtZdCdJBmqZ/erWigivdc2I9UehY7uh5ibCKZS7XRSbKomErpM4Wl2U26LPk5ukFX6ba6uShXpXXvNnyNT8P0unGMzZbFMPmojM5TkLbLZxc9oQry01O6Jt91g5rKTYgEq9HTP4ThHxM4HW5Y3qBCCitnaYw+0T6pcU/WLdApCtB4fkTRpnok0zaef4hha7mJS0d3obaqFKOJf7kGauft5JKbLRlVpeQTjs38F8g/QUtzABvcBnovHsCJPfXY6DFwaGet8wlGKAI998Py+GqnccnXONaqdZ2yARjhoB+hgB8DQ6P4Mm5lV7iLi3Am0oAHLz46NxKS70fIlF0PUAp65iPqVuqTUd3NNmhtDiKTyaDj/iBiMpLJmTSuRBvRWLcFb3RR9TJfSwNV8CU9kkIddAv6IKhQZ/yc5OCqauvNbDY9+P4nP2+UmV74SjyYStlI9LWr01OOpbDpN807flP/k93Qx/Qt/c0lDCtpDxL0+9MxPWNnSViiUPwS6x+LcmyRq6yZ/T4AAAAASUVORK5CYII=''';
const String endWithIcon =
'''iVBORw0KGgoAAAANSUhEUgAAABgAAAANCAYAAACzbK7QAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAImSURBVHgBrdLfS5NRGAfw7zvf0Spm20icMkuwBlEx+kFaVzMwKEpCWj+uEqFfF9WVdOk/EAiLIgrBi26lmwKVwggv6qblTT8u1ClSZFuuba45t/f0Pdt551H0Sh/4sL3ned/zHJ7zGNhE1ESi3YYhmjfKFwvWoIlNhAHjOn/CG+VNE+/0Ao10gaZpVFvvpAbteYHG6Yd82OasQes+P9oPB7BcsjAci+PT1O91C94mQYsU0NZfqnW5cVr9/05eM/JorP9VTFiWJRayeTGfzgkZD16MC/NyVJiX+sMObaNrNEU76Pya4t/khlRL3RSkA0da6nDvXAhDHyZR1/MMgRsDGP48g97Oo6j37Ky0SW3QRKeol25RhJ5qBXxqYxlXaY6+dp1ogcMw8GRkopywhEDk4Wu4nCZSuaVVBWSfs/SG6uk+7aUZla9VhQ3aTyly+72VUyaz+epJ8sulMjvsFl0hFz2ni7SdzmAl4nSS2tS6n7rmktlyMuBzV19sC/px92wIbpezWsD+8C19pBGaVG0ytIO0KvJ+5D0lBse+ILdUZM+PIdjoxcEmHwbudOBmxyEsForVolGSDdujnbiPMnQcK1Nkk1P2XhaVU9TzeFQk0v+EHbOJjDjdN1SdInlCjxLXCuxCZWpS6tmj5Qr0i0qyAAwRbuBdhJp3o1gSiE3PI5lRd2KV2k21SQqr469ix9q8apw1AcuBn39yNKslKp3lgK3/3VbGf7+ovf//YqvlAAAAAElFTkSuQmCC''';
const String greaterThanIcon = '''<svg width="12" height="12" viewBox="0 0 12 12" fill="none" xmlns="http://www.w3.org/2000/svg">
<defs>
<clipPath id="clip0_1798_110568">
<rect width="12" height="12" fill="white"/>
</clipPath>
</defs>
<g clip-path="url(#clip0_1798_110568)">
<path d="M0 12L12 7.5127V4.4873L0 0V3.31445L8.76762 5.99023L0 8.66602V12Z" fill="#4F4F4F"/>
</g>
</svg>''';
const String lessThanIcon = '''
<svg width="12" height="12" viewBox="0 0 12 12" fill="none" xmlns="http://www.w3.org/2000/svg">
<defs>
<clipPath id="clip0_1798_110570">
<rect width="12" height="12" fill="white" transform="translate(12 12) rotate(180)"/>
</clipPath>
</defs>
<g clip-path="url(#clip0_1798_110570)">
<path d="M12 2.68221e-07L-8.70496e-08 4.4873V7.5127L12 12V8.68555L3.23238 6.00977L12 3.33398V2.68221e-07Z" fill="#4F4F4F"/>
</g>
</svg>
''';
