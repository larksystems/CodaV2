/**
 * Represents the ViewModel of the application, mediating between the data model and the HTML view.
 */
part of coda.ui;

/// A typedef for the listener function to be called when a checkbox is changed.
typedef void CheckboxChanged(bool checked);
/// A typedef for the listener function to be called when the selected option in a selector is changed.
typedef void SelectorChanged(String valueID);

/// Maintains a sorted view model over the list of messages.
class MessageListViewModel {
  List<MessageViewModel> messages = [];
  Map<String, MessageViewModel> messageMap = {};
  List<CodeSelector> filteringCodeSelectors = [];

  MessageListViewModel();

  String sortBySeqOrSchemeId = "seq";
  bool sortAscending = true;
  bool filteringEnabled = false;

  int add(Dataset dataset, MessageViewModel messageViewModel) {
    messages.add(messageViewModel);
    messageMap[messageViewModel.message.id] = messageViewModel;
    return messages.indexOf(messageViewModel);
  }

  void sort(Dataset dataset) {
    if (messages.length == 0) return;

    if (sortBySeqOrSchemeId == "seq") {
      messages.sort((a, b) {
        int aSequenceNumber = a.message.sequenceNumber == null ? -1 : a.message.sequenceNumber;
        int bSequenceNumber = b.message.sequenceNumber == null ? -1 : b.message.sequenceNumber;

        return sortAscending ? aSequenceNumber.compareTo(bSequenceNumber)
                             : bSequenceNumber.compareTo(aSequenceNumber);
      });
      return;
    }

    Scheme scheme = dataset.codeSchemes.singleWhere((s) => s.id == sortBySeqOrSchemeId);
    var codeCompare = <MessageViewModel, String>{};
    for (var message in messages) {
      bool checked = message.getLatestLabelForSchemeId(sortBySeqOrSchemeId)?.checked;
      String checkedAsString;
      if (checked == null) {
        checkedAsString = "2";
      } else {
        checkedAsString = checked ? "0" : "1";
      }

      String codeId = message.getLatestLabelForSchemeId(sortBySeqOrSchemeId)?.codeId;
      String codeName;
      if (codeId == null || codeId == Label.MANUALLY_UNCODED) {
        codeName = '~';
      } else {
        codeName = scheme.codes.singleWhere((c) => c.id == codeId).displayText;
      }
      String sequenceNumber;
      if (message.message.sequenceNumber == null) {
        sequenceNumber = '~';
      } else {
        sequenceNumber = message.message.sequenceNumber.toString().padLeft(10, '0');
      }

      // Group all checked answers together, then by code, then sequence number
      String compareString = '$checkedAsString-$codeName-$sequenceNumber';

      codeCompare[message] = compareString;
    }
    messages.sort(
      (a, b) => sortAscending ? codeCompare[a].compareTo(codeCompare[b])
                              : codeCompare[b].compareTo(codeCompare[a]));
  }

  void filter() {
    if (messages.length == 0) return;
    if (!filteringEnabled) {
      for (var message in messages) {
        message.viewElement.style.removeProperty('display');
      }
      return;
    }

    for (var message in messages) {
      bool pass = true;
      for (int i = 0; i < message.codeSelectors.length; i++) {
        if (filteringCodeSelectors[i].selectedOption == CodeSelector.EMPTY_CODE_VALUE) continue;
        if (message.codeSelectors[i].selectedOption == filteringCodeSelectors[i].selectedOption) continue;
        pass = false;
        break;
      }
      if (pass) {
        message.viewElement.style.removeProperty('display');
      } else {
        message.viewElement.style.display = 'none';
      }
    }
  }

  labelMessage(Dataset dataset, String messageId, String schemeId, String selectedOption) {
    messageMap[messageId].schemeCodeChanged(dataset, schemeId, selectedOption);
    sort(dataset);
    filter();
  }
}

/// A ViewModel for a message, corresponding to a table row in the UI.
class MessageViewModel {
  Message message;
  TableRowElement viewElement;
  List<CodeSelector> codeSelectors = [];

  MessageViewModel(this.message, Dataset dataset) {
    viewElement = new TableRowElement();
    viewElement.classes.add('message-row');
    viewElement.setAttribute('message-id', '${message.id}');
    viewElement.addCell()
      ..classes.add('message-seq')
      ..text = '${message.sequenceNumber == null ? "N/A" : message.sequenceNumber}';
    viewElement.addCell()
      ..classes.add('message-text')
      ..text = message.text;

    dataset.codeSchemes.forEach((scheme) {
      CodeSelector codeSelector = new CodeSelector(scheme);
      codeSelectors.add(codeSelector);
      displayLatestLabelForCodeSelector(codeSelector);
      viewElement.addCell()
        ..classes.add('message-code')
        ..append(codeSelector.viewElement);
    });

    // Update the next code scheme in the list to show only a subset of the tags
    codeSelectors.forEach((codeSelector) => _updateCodeSchemeOptions(codeSelector));
  }

  schemeCheckChanged(Dataset dataset, String schemeId, bool checked) {
    final messageId = message.id;
    log.verbose("Message checkbox: $messageId $schemeId => $checked");

    var existingLabels = message.labels.where((label) => label.schemeId == schemeId);
    // Don't allow checking when a code hasn't been picked from the scheme
    if (existingLabels.isEmpty || existingLabels.first.codeId == Label.MANUALLY_UNCODED) {
      getCodeSelectorForSchemeId(schemeId).checked = false;
      log.verbose("Cancel message checkbox change on empty code: $messageId $schemeId");
      return;
    }
    // Add a new label which is the current label with the changed checkbox
    Label currentLabel = existingLabels.first;
    message.labels.insert(0,
      new Label(schemeId, new DateTime.now().toUtc(), currentLabel.codeId,
        new Origin(auth.getUserEmail(), auth.getUserName()),
        checked: checked
        ));
    fbt.updateMessage(dataset, message);

    // Update the origin
    displayLatestLabelForCodeSelector(getCodeSelectorForSchemeId(schemeId));
  }

  schemeCodeChanged(Dataset dataset, String schemeId, String codeId) {
    final messageId = message.id;
    log.verbose("Message code-value: $messageId $schemeId => $codeId");

    // If uncoding a previously coded message, mark it with a special label
    // Also prepare the checkbox status
    bool checked;
    if (codeId == CodeSelector.EMPTY_CODE_VALUE) {
      codeId = Label.MANUALLY_UNCODED;
      checked = false;
    } else {
      checked = true;
    }

    // Update the data-model by prepending this decision
    message.labels.insert(0,
      new Label(schemeId, new DateTime.now().toUtc(), codeId,
        new Origin(auth.getUserEmail(), auth.getUserName()),
        checked: checked
        ));
    fbt.updateMessage(dataset, message);

    // Update the checkbox and origin
    displayLatestLabelForCodeSelector(getCodeSelectorForSchemeId(schemeId));

    // Update the next code scheme in the list to show only a subset of the tags
    _updateCodeSchemeOptions(getCodeSelectorForSchemeId(schemeId));
  }

  void update(Message newMessage) {
    // The only changes we expect are in the coding, so warn if the id or text has changed.
    if (newMessage.id != message.id) {
      log.log("updateMessage: Warning! The ID of the updated message (id=${newMessage.id}) differs from the ID of the existing message (id=${message.id})");
    }
    if (newMessage.text != message.text) {
      log.log("updateMessage: Warning! The text of the updated message differs from the ID of the existing message (message-seq=${message.id})");
    }
    this.message = newMessage;
    codeSelectors.forEach((codeSelector) => displayLatestLabelForCodeSelector(codeSelector));

    // Update the next code scheme in the list to show only a subset of the tags
    codeSelectors.forEach((codeSelector) => _updateCodeSchemeOptions(codeSelector));
  }

  CodeSelector getCodeSelectorForSchemeId(String schemeId) =>
    codeSelectors.singleWhere((selector) => selector.scheme.id == schemeId);

  Label getLatestLabelForSchemeId(String schemeId) {
    var existingLabels = message.labels.where((label) => label.schemeId == schemeId);
    if (existingLabels.isNotEmpty) {
      return existingLabels.first;
    }
    return null;
  }

  void displayLatestLabelForCodeSelector(CodeSelector codeSelector) {
    Label label = getLatestLabelForSchemeId(codeSelector.scheme.id);
    if (label != null) {
      codeSelector.selectedOption = label.codeId == Label.MANUALLY_UNCODED ? CodeSelector.EMPTY_CODE_VALUE : label.codeId;
      codeSelector.checked = label.checked;
      if (label.labelOrigin.originType == Label.AUTOMATIC_ORIGIN_TYPE) {
        codeSelector.isManualLabel = false;
        codeSelector.confidence = label.confidence;
        codeSelector.origin = '${label.labelOrigin.name} (${label.confidence.toStringAsFixed(3)})';
        return;
      }
      codeSelector.isManualLabel = true;
      codeSelector.origin = label.labelOrigin.name;
      return;
    }
    codeSelector.selectedOption = CodeSelector.EMPTY_CODE_VALUE;
    codeSelector.checked = false;
    codeSelector.origin = '';
  }


  void _updateCodeSchemeOptions(CodeSelector codeSelector) => updateCodeSchemeOptions(codeSelector, codeSelectors);
}

final _ifrcSchemes = ["Scheme-0feedback", "Scheme-1category", "Scheme-2code"];
void updateCodeSchemeOptions(CodeSelector codeSelector, List<CodeSelector> codeSelectors) {
  // Do nothing if it's not the IFRC project
  if (!_ifrcSchemes.contains(codeSelector.scheme.id)) {
    return;
  }
  var selectedOption = codeSelector.selectedOption;
  var selectedCode = codeSelector.scheme.codes.singleWhere((element) => element.id == selectedOption, orElse: () => null);
  var index = codeSelectors.indexOf(codeSelector);
  if (index == 0) {
    if (selectedOption == CodeSelector.EMPTY_CODE_VALUE) {
      codeSelectors[1].showAllOptions();
      codeSelectors[2].showAllOptions();
      return;
    }
    List<String> categories = ifrc_demo_code_hierarchy[selectedCode.displayText].keys.toList();
    List<String> codes = [];
    for (var category in categories) {
      codes.addAll(ifrc_demo_code_hierarchy[selectedCode.displayText][category]);
    }
    codeSelectors[1].showOnlySubsetOptions(categories);
    codeSelectors[2].showOnlySubsetOptions(codes);
    return;
  }
  if (index == 1) {
    var typeCodeSelector = codeSelectors[0];
    var selectedTypeOption = typeCodeSelector.selectedOption;
    var selectedTypeCode = typeCodeSelector.scheme.codes.singleWhere((element) => element.id == selectedTypeOption, orElse: () => null);

    if (selectedOption == CodeSelector.EMPTY_CODE_VALUE) {
      if (selectedTypeCode == null) {
        codeSelectors[2].showAllOptions();
        return;
      }
      List<String> categories = ifrc_demo_code_hierarchy[selectedTypeCode.displayText].keys.toList();
      List<String> codes = [];
      for (var category in categories) {
        codes.addAll(ifrc_demo_code_hierarchy[selectedTypeCode.displayText][category]);
      }
      codeSelectors[2].showOnlySubsetOptions(codes);
      return;
    }

    for (var type in ifrc_demo_code_hierarchy.keys) {
      if (ifrc_demo_code_hierarchy[type].keys.contains(selectedCode.displayText)) {
        codeSelectors[2].showOnlySubsetOptions(ifrc_demo_code_hierarchy[type][selectedCode.displayText]);
        return;
      }
    }
  }
}

/// A dropdown code selector used to label a message within a coding scheme.
class CodeSelector {
  DivElement viewElement;
  InputElement checkbox;
  SelectElement dropdown;
  Element warning;
  DivElement originElement;

  static CodeSelector _activeCodeSelector;
  static CodeSelector get activeCodeSelector => _activeCodeSelector;
  static set activeCodeSelector(CodeSelector activeCodeSelector) {
    _activeCodeSelector?.viewElement?.classes?.toggle('active', false);

    if (_activeCodeSelector?.viewElement != null) {
      Element messageElement = getAncestors(_activeCodeSelector.viewElement).firstWhere((a) => a.classes.contains('message-row'));
      messageElement.classes.toggle('active', false);
    }
    // _activeCodeSelector?.viewElement?.parent?.parent?.classes?
    // Focus on the new code selector
    _activeCodeSelector = activeCodeSelector;
    if (_activeCodeSelector == null) return;

    _activeCodeSelector.viewElement.classes.toggle('active', true);
    if (_activeCodeSelector?.viewElement != null) {
      Element messageElement = getAncestors(_activeCodeSelector.viewElement).firstWhere((a) => a.classes.contains('message-row'));
      messageElement.classes.toggle('active', true);
    }
    _activeCodeSelector.dropdown.focus();
  }

  static const EMPTY_CODE_VALUE = 'unassign';
  static const MIN_CONFIDENCE_LIMIT = 0.8;
  static const BASE_LUMINOSITY = 50;
  static const MAX_LUMINOSITY_LIMIT = 90;

  Scheme scheme;

  CodeSelector(this.scheme) {
    viewElement = new DivElement();
    viewElement.classes.add('input-group');
    viewElement.attributes['scheme-id'] = scheme.id;

    // TODO: Implement checkbox read from the scheme
    checkbox = new InputElement(type: 'checkbox');
    viewElement.append(checkbox);

    dropdown = new SelectElement();
    dropdown.classes.add('code-selector');
    // An empty code used to unlabel the message
    OptionElement option = new OptionElement();
    option
      ..attributes['schemeid'] = scheme.id
      ..attributes['valueid'] = EMPTY_CODE_VALUE
      ..attributes['value'] = EMPTY_CODE_VALUE
      ..selected = true;
    dropdown.append(option);
    scheme.codes.forEach((code) {
      if (!code.visibleInCoda) return;
      String shortcutDisplayText = code.shortcut == null ? '' : '(${code.shortcut})';
      OptionElement option = new OptionElement();
      option
        ..attributes['schemeid'] = scheme.id
        ..attributes['valueid'] = code.id
        ..attributes['value'] = code.displayText
        ..text = "${code.displayText} $shortcutDisplayText";
      dropdown.append(option);
    });
    viewElement.append(dropdown);

    warning = new SpanElement();
    warning
      ..classes.add('warning')
      ..classes.add('hidden')
      ..attributes['data-toggle'] = 'tooltip'
      ..attributes['data-placement'] = 'bottom'
      ..attributes['title'] = 'Latest code is not in code scheme or is not visible in Coda'
      ..text = '!';
    viewElement.append(warning);

    originElement = new DivElement();
    originElement.classes.add('origin');
    viewElement.append(originElement);
  }

  /// When an option from the list has been selected manually, the warning message should be hidden if it's not already.
  hideWarning() => warning.classes.toggle('hidden', true);
  showWarning() => warning.classes.toggle('hidden', false);

  set checked(bool checked) => checkbox.checked = checked;
  bool get checked => checkbox.checked;

  set selectedOption(String codeId) {
    OptionElement option = dropdown.querySelector('option[valueid="$codeId"]');
    // When the option set programmatically doesn't exist in the scheme, show the warning sign.
    if (option == null) {
      warning
        ..classes.remove('hidden')
        ..attributes['title'] = 'The message is pre-labelled with the code "$codeId" that doesn\'t exist in the scheme';
    } else {
      option.selected = true;
    }
  }

  set isManualLabel(bool isManualLabel) {
    if (isManualLabel) {
      dropdown.style.background = '';
      return;
    }
    dropdown.style.background = 'hsl(50, 100%, 50%)';
  }

  /// Sets the confidence of the code in the UI.
  /// Expected range: 0.0 - 1.0
  set confidence(double confidence) {
    if (confidence < 0.0 || confidence > 1.0) {
      log.severe('Unexpected confidence value $confidence for scheme id ${scheme.id}');
    }
    confidence = math.max(confidence, MIN_CONFIDENCE_LIMIT);
    // Normalize the confidence
    double normalized_confidence = (confidence - MIN_CONFIDENCE_LIMIT) /  (1.0 - MIN_CONFIDENCE_LIMIT);
    // Compute the luminosity between BASE_LUMINOSITY (0 confidence) and MAX_LUMINOSITY_LIMIT (100% confidence)
    int luminosity = BASE_LUMINOSITY + (normalized_confidence * (MAX_LUMINOSITY_LIMIT - BASE_LUMINOSITY)).toInt();
    dropdown.style.background = 'hsl(50, 100%, $luminosity%)';
  }

  String get selectedOption => dropdown.selectedOptions[0].attributes['valueid'];

  set origin(String text) => originElement.text = text;

  focus() {
    dropdown.focus();
  }

  void showOnlySubsetOptions(Iterable<String> subsetValues) {
    for (var option in this.dropdown.options) {
      if (option.value == EMPTY_CODE_VALUE) {
        option.hidden = false;
        continue;
      }
      option.hidden = !subsetValues.contains(option.attributes['value']);
    }
    var selectedValue = dropdown.selectedOptions[0].attributes['value'];
    var subsetValuesWithUnassign = new List.from(subsetValues)..add(EMPTY_CODE_VALUE);
    if (subsetValuesWithUnassign.contains(selectedValue)) {
      hideHierarchyWarning();
      return;
    }
    Element messageElement = getAncestors(viewElement).firstWhere((a) => a.classes.contains('message-row'), orElse: () => null);
    if (messageElement == null) {
      print('Warning: ${selectedValue} not in the subset values for selector ${scheme.name}');
      showHierarchyWarning();
      return;
    }
    var seqNo = messageElement.firstChild.text;
    print('Warning: ${selectedValue} not in the subset values (message id ${seqNo})');
    showHierarchyWarning();
  }

  void showHierarchyWarning() {
    dropdown.classes.toggle('code-selector--warning', true);
  }

  void hideHierarchyWarning() {
    dropdown.classes.toggle('code-selector--warning', false);
  }

  void showAllOptions() {
    for (var option in dropdown.options) {
      option.hidden = false;
      dropdown.classes.toggle('code-selector--warning', false);
    }
  }
}
