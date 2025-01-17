// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.diet_parser;

import 'package:_fe_analyzer_shared/src/scanner/token.dart' show Token;

import 'package:_fe_analyzer_shared/src/parser/parser.dart'
    show ClassMemberParser, Listener, MemberKind;

const bool useImplicitCreationExpressionInCfe = true;

// TODO(ahe): Move this to parser package.
class DietParser extends ClassMemberParser {
  DietParser(Listener listener)
      : super(listener,
            useImplicitCreationExpression: useImplicitCreationExpressionInCfe);

  Token parseFormalParametersRest(Token token, MemberKind kind) {
    return skipFormalParametersRest(token, kind);
  }
}
