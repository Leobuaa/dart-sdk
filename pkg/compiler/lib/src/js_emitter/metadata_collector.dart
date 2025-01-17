// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.js_emitter.metadata_collector;

import 'package:js_ast/src/precedence.dart' as js_precedence;

import '../common.dart';
import '../deferred_load/output_unit.dart' show OutputUnit;

import '../elements/types.dart';
import '../js/js.dart' as jsAst;
import '../js_backend/runtime_types_new.dart' show RecipeEncoder;
import '../js_model/type_recipe.dart' show TypeExpressionRecipe;

import 'code_emitter_task.dart' show Emitter;

/// Represents an entry's position in one of the global metadata arrays.
///
/// [_rc] is used to count the number of references of the token in the
/// ast for a program.
/// [value] is the actual position, once they have been finalized.
abstract class _MetadataEntry extends jsAst.DeferredNumber
    implements Comparable, jsAst.ReferenceCountedAstNode {
  jsAst.Expression get entry;
  @override
  int get value;
  int get _rc;

  // Mark this entry as seen. On the first time this is seen, the visitor
  // will be applied to the [entry] to also mark potential [_MetadataEntry]
  // instances in the [entry] as seen.
  @override
  void markSeen(jsAst.TokenCounter visitor);
}

class BoundMetadataEntry extends _MetadataEntry {
  int _value = -1;
  @override
  int _rc = 0;
  @override
  final jsAst.Expression entry;

  BoundMetadataEntry(this.entry);

  @override
  bool get isFinalized => _value != -1;

  finalize(int value) {
    assert(!isFinalized);
    _value = value;
  }

  @override
  int get value {
    assert(isFinalized);
    return _value;
  }

  bool get isUsed => _rc > 0;

  @override
  void markSeen(jsAst.BaseVisitor visitor) {
    _rc++;
    if (_rc == 1) entry.accept(visitor);
  }

  @override
  int compareTo(covariant _MetadataEntry other) => other._rc - this._rc;

  @override
  String toString() => 'BoundMetadataEntry($hashCode,rc=$_rc,_value=$_value)';
}

class _MetadataList extends jsAst.DeferredExpression {
  jsAst.Expression _value;

  void setExpression(jsAst.Expression value) {
    assert(_value == null);
    assert(value.precedenceLevel == this.precedenceLevel);
    _value = value;
  }

  @override
  jsAst.Expression get value {
    assert(_value != null);
    return _value;
  }

  @override
  int get precedenceLevel => js_precedence.PRIMARY;
}

class MetadataCollector implements jsAst.TokenFinalizer {
  final DiagnosticReporter reporter;
  final Emitter _emitter;
  final RecipeEncoder _rtiRecipeEncoder;

  /// A map used to canonicalize the entries of metadata.
  Map<OutputUnit, Map<String, List<BoundMetadataEntry>>> _metadataMap = {};

  /// A map with a token for a lists of JS expressions, one token for each
  /// output unit. Once finalized, the entries represent types including
  /// function types and typedefs.
  Map<OutputUnit, _MetadataList> _typesTokens = {};

  /// A map used to canonicalize the entries of types.
  Map<OutputUnit, Map<DartType, List<BoundMetadataEntry>>> _typesMap = {};

  MetadataCollector(this.reporter, this._emitter, this._rtiRecipeEncoder);

  jsAst.Expression getTypesForOutputUnit(OutputUnit outputUnit) {
    return _typesTokens.putIfAbsent(outputUnit, () => new _MetadataList());
  }

  void mergeOutputUnitMetadata(OutputUnit target, OutputUnit source) {
    assert(target != source);

    // Merge _metadataMap
    var sourceMetadataMap = _metadataMap[source];
    if (sourceMetadataMap != null) {
      var targetMetadataMap =
          _metadataMap[target] ??= Map<String, List<BoundMetadataEntry>>();
      _metadataMap.remove(source);
      sourceMetadataMap.forEach((str, entries) {
        var targetMetadataMapList = targetMetadataMap[str] ??= [];
        targetMetadataMapList.addAll(entries);
      });
    }

    // Merge _typesMap
    var sourceTypesMap = _typesMap[source];
    if (sourceTypesMap != null) {
      var targetTypesMap =
          _typesMap[target] ??= Map<DartType, List<BoundMetadataEntry>>();
      _typesMap.remove(source);
      sourceTypesMap.forEach((type, entries) {
        var targetTypesMapList = targetTypesMap[type] ??= [];
        targetTypesMapList.addAll(entries);
      });
    }
  }

  jsAst.Expression reifyType(DartType type, OutputUnit outputUnit) {
    return _addTypeInOutputUnit(type, outputUnit);
  }

  jsAst.Expression _computeTypeRepresentationNewRti(DartType type) {
    return _rtiRecipeEncoder.encodeGroundRecipe(
        _emitter, TypeExpressionRecipe(type));
  }

  jsAst.Expression _addTypeInOutputUnit(DartType type, OutputUnit outputUnit) {
    _typesMap[outputUnit] ??= Map<DartType, List<BoundMetadataEntry>>();
    BoundMetadataEntry metadataEntry;

    if (_typesMap[outputUnit].containsKey(type)) {
      metadataEntry = _typesMap[outputUnit][type].single;
    } else {
      _typesMap[outputUnit].putIfAbsent(type, () {
        metadataEntry =
            BoundMetadataEntry(_computeTypeRepresentationNewRti(type));
        return [metadataEntry];
      });
    }
    return metadataEntry;
  }

  @override
  void finalizeTokens() {
    void countTokensInTypes(Iterable<BoundMetadataEntry> entries) {
      jsAst.TokenCounter counter = new jsAst.TokenCounter();
      entries
          .where((BoundMetadataEntry e) => e._rc > 0)
          .map((BoundMetadataEntry e) => e.entry)
          .forEach(counter.countTokens);
    }

    jsAst.ArrayInitializer finalizeMap(
        Map<dynamic, List<BoundMetadataEntry>> map) {
      List<BoundMetadataEntry> entries = [
        for (var entriesList in map.values)
          for (var entry in entriesList)
            if (entry.isUsed) entry
      ];
      entries.sort();

      // TODO(herhut): Bucket entries by index length and use a stable
      //               distribution within buckets.
      int count = 0;
      for (BoundMetadataEntry entry in entries) {
        entry.finalize(count++);
      }

      List<jsAst.Node> values =
          entries.map((BoundMetadataEntry e) => e.entry).toList();

      return new jsAst.ArrayInitializer(values);
    }

    _typesTokens.forEach((OutputUnit outputUnit, _MetadataList token) {
      Map<DartType, List<BoundMetadataEntry>> typesMap = _typesMap[outputUnit];
      if (typesMap != null) {
        typesMap.values.forEach(countTokensInTypes);
        token.setExpression(finalizeMap(typesMap));
      } else {
        token.setExpression(new jsAst.ArrayInitializer([]));
      }
    });
  }
}
