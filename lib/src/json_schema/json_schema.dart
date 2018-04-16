// Copyright 2013-2018 Workiva Inc.
//
// Licensed under the Boost Software License (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.boost.org/LICENSE_1_0.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// This software or document includes material copied from or derived
// from JSON-Schema-Test-Suite (https://github.com/json-schema-org/JSON-Schema-Test-Suite),
// Copyright (c) 2012 Julian Berman, which is licensed under the following terms:
//
//     Copyright (c) 2012 Julian Berman
//
//     Permission is hereby granted, free of charge, to any person obtaining a copy
//     of this software and associated documentation files (the "Software"), to deal
//     in the Software without restriction, including without limitation the rights
//     to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//     copies of the Software, and to permit persons to whom the Software is
//     furnished to do so, subject to the following conditions:
//
//     The above copyright notice and this permission notice shall be included in
//     all copies or substantial portions of the Software.
//
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//     AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//     OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//     THE SOFTWARE.

import 'dart:async';

import 'package:path/path.dart' as path_lib;

import 'package:json_schema/src/json_schema/schema_type.dart';
import 'package:json_schema/src/json_schema/validator.dart';
import 'package:json_schema/src/json_schema/global_platform_functions.dart';
import 'package:json_schema/src/json_schema/utils.dart';
import 'package:json_schema/src/json_schema/format_exceptions.dart';
import 'package:json_schema/src/json_schema/type_validators.dart';

typedef dynamic SchemaPropertySetter(JsonSchema s, dynamic value);
typedef SchemaAssigner(JsonSchema s);
typedef SchemaAdder(JsonSchema s);

/// Constructed with a json schema, either as string or Map. Validation of
/// the schema itself is done on construction. Any errors in the schema
/// result in a FormatException being thrown.
class JsonSchema {
  JsonSchema._fromMap(this._root, this._schemaMap, this._path) {
    _initialize();
    _addSchema(path, this);
  }

  JsonSchema._fromBool(this._root, this._schemaBool, this._path) {
    _initialize();
    _addSchema(path, this);
  }

  JsonSchema._fromRootMap(this._schemaMap) {
    _initialize();
  }

  /// Create a schema from a [Map].
  ///
  /// This method is asyncronous to support automatic fetching of sub-[JsonSchema]s for items,
  /// properties, and sub-properties of the root schema.
  ///
  /// TODO: If you want to create a [JsonSchema],
  /// first ensure you have fetched all sub-schemas out of band, and use [createSchemaWithProvidedRefs]
  /// instead.
  ///
  /// Typically the supplied [Map] is result of [JSON.decode] on a JSON [String].
  static Future<JsonSchema> createSchema(Map data) => new JsonSchema._fromRootMap(data)._thisCompleter.future;

  /// Create a schema from a URL.
  ///
  /// This method is asyncronous to support automatic fetching of sub-[JsonSchema]s for items,
  /// properties, and sub-properties of the root schema.
  static Future<JsonSchema> createSchemaFromUrl(String schemaUrl) {
    if (globalCreateJsonSchemaFromUrl == null) {
      throw new StateError('no globalCreateJsonSchemaFromUrl defined!');
    }
    return globalCreateJsonSchemaFromUrl(schemaUrl);
  }

  /// Construct and validate a JsonSchema.
  Future<JsonSchema> _initialize() {
    if (_root == null) {
      _root = this;
      _path = '#';
      _addSchema('#', this);
      _thisCompleter = new Completer();
    } else {
      _schemaRefs = _root._schemaRefs;
      _refMap = _root._refMap;
      _freeFormMap = _root._freeFormMap;
      _thisCompleter = _root._thisCompleter;
      _schemaAssignments = _root._schemaAssignments;
    }
    return _validateSchemaAsync();
  }

  /// Calculate, validate and set all properties defined in the JSON Schema spec.
  ///
  /// Doesn't validate interdependent properties. See [_validateInterdependentProperties]
  void _validateAndSetIndividualProperties() {
    // Iterate over all string keys of the root JSON Schema Map. Calculate, validate and
    // set all properties according to spec.
    _schemaMap.forEach((k, v) {
      /// Get the _set<X> method from the [_accessMap] based on the [Map] string key.
      final SchemaPropertySetter accessor = _accessMap[k];
      if (accessor != null) {
        accessor(this, v);
      } else {
        _freeFormMap[path_lib.join(_path, JsonSchemaUtils.normalizePath(k))] = v;
      }
    });
  }

  void _validateInterdependentProperties() {
    // Check that a minimum is set if both exclusiveMinimum and minimum properties are set.
    if (_exclusiveMinimum != null && _minimum == null)
      throw FormatExceptions.error('exclusiveMinimum requires minimum');

    // Check that a minimum is set if both exclusiveMaximum and maximum properties are set.
    if (_exclusiveMaximum != null && _maximum == null)
      throw FormatExceptions.error('exclusiveMaximum requires maximum');
  }

  /// Validate, calculate and set all properties on the [JsonSchema], included properties
  /// that have interdependencies.
  void _validateAndSetAllProperties() {
    _validateAndSetIndividualProperties();
    _validateInterdependentProperties();
  }

  Future<JsonSchema> _validateAllPathsAsync() {
    if (_root == this) {
      _schemaAssignments.forEach((assignment) => assignment());
      if (_retrievalRequests.isNotEmpty) {
        Future.wait(_retrievalRequests).then((_) => _thisCompleter.complete(_resolvePath('#')));
      } else {
        _thisCompleter.complete(_resolvePath('#'));
      }
      // _logger.info('Marked $_path complete'); TODO: re-add logger
    }
    return _thisCompleter.future;
  }

  /// Validate that a given [JsonSchema] conforms to the official JSON Schema spec.
  Future<JsonSchema> _validateSchemaAsync() {
    // _logger.info('Validating schema $_path'); TODO: re-add logger

    _registerSchemaRef(_path, _schemaMap);

    if (_isRemoteRef(_path, _schemaMap)) {
      // _logger.info('Top level schema is ref: $_schemaRefs'); TODO: re-add logger
    }

    _validateAndSetAllProperties();
    return _validateAllPathsAsync();

    // _logger.info('Completed Validating schema $_path'); TODO: re-add logger
  }

  /// Given a path, find the ref'd [JsonSchema] from the map.
  JsonSchema _resolvePath(String original) {
    final String path = endPath(original);
    final JsonSchema result = _refMap[path];
    if (result == null) {
      final schema = _freeFormMap[path];
      if (schema is! Map) throw FormatExceptions.schema('free-form property $original at $path', schema);
      return new JsonSchema._fromMap(_root, schema, path);
    }
    return result;
  }

  JsonSchema _createSubSchema(dynamic schemaDefinition, String path) {
    assert(!_schemaRefs.containsKey(path));
    assert(!_refMap.containsKey(path));
    if (schemaDefinition is bool) {
      return new JsonSchema._fromBool(_root, schemaDefinition, path);
    } else {
      return new JsonSchema._fromMap(_root, schemaDefinition, path);
    }
  }

  // --------------------------------------------------------------------------
  // Root Schema Fields
  // --------------------------------------------------------------------------

  /// The root [JsonSchema] for this [JsonSchema].
  JsonSchema _root;

  /// JSON of the [JsonSchema] as a [Map]. Only this value or [_schemaBool] should be set, not both.
  Map<String, dynamic> _schemaMap = {};

  /// JSON of the [JsonSchema] as a [bool]. Only this value or [_schemaMap] should be set, not both.
  bool _schemaBool;

  /// A [List<JsonSchema>] which the value must conform to all of.
  List<JsonSchema> _allOf = [];

  /// A [List<JsonSchema>] which the value must conform to at least one of.
  List<JsonSchema> _anyOf = [];

  /// Default value of the [JsonSchema].
  dynamic _defaultValue;

  /// Included [JsonSchema] definitions.
  Map<String, JsonSchema> _definitions = {};

  /// Description of the [JsonSchema].
  String _description;

  /// Possible values of the [JsonSchema].
  List _enumValues = [];

  /// Whether the maximum of the [JsonSchema] is exclusive.
  bool _exclusiveMaximum;

  /// Whether the minumum of the [JsonSchema] is exclusive.
  bool _exclusiveMinimum;

  /// Pre-defined format (i.e. date-time, email, etc) of the [JsonSchema] value.
  String _format;

  /// ID of the [JsonSchema].
  Uri _id;

  /// Maximum value of the [JsonSchema] value.
  num _maximum;

  /// Minimum value of the [JsonSchema] value.
  num _minimum;

  /// Maximum value of the [JsonSchema] value.
  int _maxLength;

  /// Minimum length of the [JsonSchema] value.
  int _minLength;

  /// The number which the value of the [JsonSchema] must be a multiple of.
  num _multipleOf;

  /// A [JsonSchema] which the value must NOT be.
  JsonSchema _notSchema;

  /// A [List<JsonSchema>] which the value must conform to at least one of.
  List<JsonSchema> _oneOf = [];

  /// The regular expression the [JsonSchema] value must conform to.
  RegExp _pattern;

  /// Ref to the URI of the [JsonSchema].
  String _ref;

  /// The path of the [JsonSchema] within the root [JsonSchema].
  String _path;

  /// Title of the [JsonSchema].
  String _title;

  /// List of allowable types for the [JsonSchema].
  List<SchemaType> _schemaTypeList;

  // --------------------------------------------------------------------------
  // Schema List Item Related Fields
  // --------------------------------------------------------------------------

  /// [JsonSchema] definition used to validate items of this schema.
  JsonSchema _items;

  /// List of [JsonSchema] used to validate items of this schema.
  List<JsonSchema> _itemsList;

  /// Whether additional items are allowed or the [JsonSchema] they should conform to.
  /* union bool | Map */ dynamic _additionalItems;

  /// Maimum number of items allowed.
  int _maxItems;

  /// Maimum number of items allowed.
  int _minItems;

  /// Whether the items in the list must be unique.
  bool _uniqueItems = false;

  // --------------------------------------------------------------------------
  // Schema Sub-Property Related Fields
  // --------------------------------------------------------------------------

  /// Map of [JsonSchema]s by property key.
  Map<String, JsonSchema> _properties = {};

  /// Whether additional properties, other than those specified, are allowed.
  bool _additionalProperties;

  /// [JsonSchema] that additional properties must conform to.
  JsonSchema _additionalPropertiesSchema;

  Map<String, List<String>> _propertyDependencies = {};

  Map<String, JsonSchema> _schemaDependencies = {};

  /// The maximum number of properties allowed.
  int _maxProperties;

  /// The minimum number of properties allowed.
  int _minProperties = 0;

  /// Map of [JsonSchema]s for properties, based on [RegExp]s keys.
  Map<RegExp, JsonSchema> _patternProperties = {};

  Map<String, JsonSchema> _refMap = {};
  List<String> _requiredProperties;

  // --------------------------------------------------------------------------
  // Implementation Specific Feilds
  // --------------------------------------------------------------------------

  /// Maps any unsupported top level property to its original value
  Map<String, dynamic> _freeFormMap = {};

  /// Set of strings to gaurd against path cycles
  Set<String> _pathsEncountered = new Set();

  /// HTTP(S) requests to fetch ref'd schemas.
  List<Future<JsonSchema>> _retrievalRequests = [];

  /// Assignments to call for resolution upon end of parse.
  List _schemaAssignments = [];

  /// For schemas with $ref maps, path of schema to $ref path
  Map<String, String> _schemaRefs = {};

  /// Completer that fires when [this] [JsonSchema] has finished building.
  Completer _thisCompleter = new Completer();

  /// Map to allow getters to be accessed by String key.
  static Map<String, SchemaPropertySetter> _accessMap = {
    // Root Schema Properties
    'allOf': (JsonSchema s, dynamic v) => s._setAllOf(v),
    'anyOf': (JsonSchema s, dynamic v) => s._setAnyOf(v),
    'default': (JsonSchema s, dynamic v) => s._setDefault(v),
    'definitions': (JsonSchema s, dynamic v) => s._setDefinitions(v),
    'description': (JsonSchema s, dynamic v) => s._setDescription(v),
    'enum': (JsonSchema s, dynamic v) => s._setEnum(v),
    'exclusiveMaximum': (JsonSchema s, dynamic v) => s._setExclusiveMaximum(v),
    'exclusiveMinimum': (JsonSchema s, dynamic v) => s._setExclusiveMinimum(v),
    'format': (JsonSchema s, dynamic v) => s._setFormat(v),
    'id': (JsonSchema s, dynamic v) => s._setId(v),
    'maximum': (JsonSchema s, dynamic v) => s._setMaximum(v),
    'minimum': (JsonSchema s, dynamic v) => s._setMinimum(v),
    'maxLength': (JsonSchema s, dynamic v) => s._setMaxLength(v),
    'minLength': (JsonSchema s, dynamic v) => s._setMinLength(v),
    'multipleOf': (JsonSchema s, dynamic v) => s._setMultipleOf(v),
    'not': (JsonSchema s, dynamic v) => s._setNot(v),
    'oneOf': (JsonSchema s, dynamic v) => s._setOneOf(v),
    'pattern': (JsonSchema s, dynamic v) => s._setPattern(v),
    '\$ref': (JsonSchema s, dynamic v) => s._setRef(v),
    '\$schema': (JsonSchema s, dynamic v) => s._setSchema(v),
    'title': (JsonSchema s, dynamic v) => s._setTitle(v),
    'type': (JsonSchema s, dynamic v) => s._setType(v),
    // Schema List Item Related Fields
    'items': (JsonSchema s, dynamic v) => s._setItems(v),
    'additionalItems': (JsonSchema s, dynamic v) => s._setAdditionalItems(v),
    'maxItems': (JsonSchema s, dynamic v) => s._setMaxItems(v),
    'minItems': (JsonSchema s, dynamic v) => s._setMinItems(v),
    'uniqueItems': (JsonSchema s, dynamic v) => s._setUniqueItems(v),
    // Schema Sub-Property Related Fields
    'properties': (JsonSchema s, dynamic v) => s._setProperties(v),
    'additionalProperties': (JsonSchema s, dynamic v) => s._setAdditionalProperties(v),
    'dependencies': (JsonSchema s, dynamic v) => s._setDependencies(v),
    'maxProperties': (JsonSchema s, dynamic v) => s._setMaxProperties(v),
    'minProperties': (JsonSchema s, dynamic v) => s._setMinProperties(v),
    'patternProperties': (JsonSchema s, dynamic v) => s._setPatternProperties(v),
    'required': (JsonSchema s, dynamic v) => s._setRequired(v),
  };

  /// Get a nested [JsonSchema] from a path.
  JsonSchema resolvePath(String path) => _resolvePath(path);

  @override
  String toString() => '${_schemaMap}';

  // --------------------------------------------------------------------------
  // Root Schema Getters
  // --------------------------------------------------------------------------

  /// The root [JsonSchema] for this [JsonSchema].
  JsonSchema get root => _root;

  /// JSON of the [JsonSchema] as a [Map]. Only this value or [_schemaBool] should be set, not both.
  Map get schemaMap => _schemaMap;

  /// JSON of the [JsonSchema] as a [bool]. Only this value or [_schemaMap] should be set, not both.
  bool get schemaBool => _schemaBool;

  /// Default value of the [JsonSchema].
  dynamic get defaultValue => _defaultValue;

  /// Included [JsonSchema] definitions.
  Map<String, JsonSchema> get definitions => _definitions;

  /// Description of the [JsonSchema].
  String get description => _description;

  /// Possible values of the [JsonSchema].
  List get enumValues => _enumValues;

  /// Whether the maximum of the [JsonSchema] is exclusive.
  bool get exclusiveMaximum => _exclusiveMaximum ?? false;

  /// Whether the maximum of the [JsonSchema] is exclusive.
  bool get exclusiveMinimum => _exclusiveMinimum ?? false;

  /// Pre-defined format (i.e. date-time, email, etc) of the [JsonSchema] value.
  String get format => _format;

  /// ID of the [JsonSchema].
  Uri get id => _id;

  /// Maximum value of the [JsonSchema] value.
  num get maximum => _maximum;

  /// Minimum value of the [JsonSchema] value.
  num get minimum => _minimum;

  /// Maximum length of the [JsonSchema] value.
  int get maxLength => _maxLength;

  /// Minimum length of the [JsonSchema] value.
  int get minLength => _minLength;

  /// The number which the value of the [JsonSchema] must be a multiple of.
  num get multipleOf => _multipleOf;

  /// The path of the [JsonSchema] within the root [JsonSchema].
  String get path => _path;

  /// The regular expression the [JsonSchema] value must conform to.
  RegExp get pattern => _pattern;

  /// A [List<JsonSchema>] which the value must conform to all of.
  List<JsonSchema> get allOf => _allOf;

  /// A [List<JsonSchema>] which the value must conform to at least one of.
  List<JsonSchema> get anyOf => _anyOf;

  /// A [List<JsonSchema>] which the value must conform to at least one of.
  List<JsonSchema> get oneOf => _oneOf;

  /// A [JsonSchema] which the value must NOT be.
  JsonSchema get notSchema => _notSchema;

  /// Ref to the URI of the [JsonSchema].
  String get ref => _ref;

  /// Title of the [JsonSchema].
  String get title => _title;

  /// List of allowable types for the [JsonSchema].
  List<SchemaType> get schemaTypeList => _schemaTypeList;

  // --------------------------------------------------------------------------
  // Schema List Item Related Getters
  // --------------------------------------------------------------------------

  /// Single [JsonSchema] sub items of this [JsonSchema] must conform to.
  JsonSchema get items => _items;

  /// Ordered list of [JsonSchema] which the value of the same index must conform to.
  List<JsonSchema> get itemsList => _itemsList;

  /// Whether additional items are allowed or the [JsonSchema] they should conform to.
  /* union bool | Map */ dynamic get additionalItems => _additionalItems;

  /// The maximum number of items allowed.
  int get maxItems => _maxItems;

  /// The minimum number of items allowed.
  int get minItems => _minItems;

  /// Whether the items in the list must be unique.
  bool get uniqueItems => _uniqueItems;

  // --------------------------------------------------------------------------
  // Schema Sub-Property Related Getters
  // --------------------------------------------------------------------------

  /// Map of [JsonSchema]s for properties, by [String] key.
  Map<String, JsonSchema> get properties => _properties;

  /// Whether additional properties, other than those specified, are allowed.
  bool get additionalProperties => _additionalProperties;

  /// [JsonSchema] that additional properties must conform to.
  JsonSchema get additionalPropertiesSchema => _additionalPropertiesSchema;

  /// The maximum number of properties allowed.
  int get maxProperties => _maxProperties;

  /// The minimum number of properties allowed.
  int get minProperties => _minProperties;

  /// Map of [JsonSchema]s for properties, based on [RegExp]s keys.
  Map<RegExp, JsonSchema> get patternProperties => _patternProperties;

  /// TODO: write an informative comment for this.
  Map<String, List<String>> get propertyDependencies => _propertyDependencies;

  /// Map of sub-properties' [JsonSchema] by path. TODO: this might be inaccurate.
  Map<String, JsonSchema> get refMap => _refMap;

  /// Properties that must be inclueded for the [JsonSchema] to be valid.
  List<String> get requiredProperties => _requiredProperties;

  /// TODO: write an informative comment for this.
  Map<String, JsonSchema> get schemaDependencies => _schemaDependencies;

  // --------------------------------------------------------------------------
  // Convenience Methods
  // --------------------------------------------------------------------------

  /// Given path, follow all references to an end path pointing to [JsonSchema].
  String endPath(String path) {
    _pathsEncountered.clear();
    return _endPath(path);
  }

  /// Recursive inner-function for [endPath].
  String _endPath(String path) {
    // TODO: We probably shouldn't throw here, and properly support cyclical schemas, since they
    // are allowed in the spec.
    if (_pathsEncountered.contains(path))
      throw FormatExceptions.error('Encountered path cycle ${_pathsEncountered}, adding $path');

    final referredTo = _schemaRefs[path];
    if (referredTo == null) {
      return path;
    } else {
      _pathsEncountered.add(path);
      return _endPath(referredTo);
    }
  }

  /// Returns paths of all paths
  Set get paths => new Set.from(_schemaRefs.keys)..addAll(_refMap.keys);

  /// Whether a given property is required for the [JsonSchema] instance to be valid.
  bool propertyRequired(String property) => _requiredProperties != null && _requiredProperties.contains(property);

  /// Validate [instance] against this schema
  bool validate(dynamic instance) => new Validator(this).validate(instance);

  // --------------------------------------------------------------------------
  // JSON Schema Internal Operations
  // --------------------------------------------------------------------------

  /// Function to determine whether a given [schemaDefinition] is a remote $ref.
  bool _isRemoteRef(String path, dynamic schemaDefinition) {
    Map schemaDefinitionMap;
    try {
      schemaDefinitionMap = TypeValidators.object(path, schemaDefinition);
    } catch (e) {
      // If the schema definition isn't an object, return early, since it can't be a ref.
      return false;
    }

    final dynamic ref = schemaDefinitionMap[r'$ref'];
    if (ref != null) {
      TypeValidators.nonEmptyString(r'$ref', ref);
      // If the ref begins with "#" it is a local ref, so we return false.
      if (ref[0] != '#') return false;
      return true;
    }
    return false;
  }

  /// Checks if a [schemaDefinition] has a $ref.
  /// If it does, it adds the $ref to [_shemaRefs] at the path key and returns true.
  void _registerSchemaRef(String path, dynamic schemaDefinition) {
    if (_isRemoteRef(path, schemaDefinition)) {
      final schemaDefinitionMap = TypeValidators.object(path, schemaDefinition);
      final ref = schemaDefinitionMap[r'$ref'];
      // _logger.info('Linking $path to $ref'); TODO: re-add logger
      _schemaRefs[path] = ref;
    }
  }

  /// Add a ref'd JsonSchema to the map of available Schemas.
  _addSchema(String path, JsonSchema schema) => _refMap[path] = schema;

  // Create a [JsonSchema] from a sub-schema of the root.
  _makeSchema(String path, dynamic schema, SchemaAssigner assigner) {
    if (schema is! Map && schema is! bool) throw FormatExceptions.schema(path, schema);

    _registerSchemaRef(path, schema);

    final isRemoteReference = _isRemoteRef(path, schema);
    final isPathLocal = path[0] == '#';

    /// If this sub-schema is a ref within the root schema,
    /// add it to the map of local schema assignments.
    /// Otherwise, call the assigner function and create a new [JsonSchema].
    if (isRemoteReference && isPathLocal) {
      _schemaAssignments.add(() => assigner(_resolvePath(path)));
    } else {
      assigner(_createSubSchema(schema, path));
    }
  }

  // --------------------------------------------------------------------------
  // Internal Property Validators
  // --------------------------------------------------------------------------

  _validateListOfSchema(String key, dynamic value, SchemaAdder schemaAdder) {
    TypeValidators.nonEmptyList(key, value);
    for (int i = 0; i < value.length; i++) {
      _makeSchema('$_path/$key/$i', value[i], (rhs) => schemaAdder(rhs));
    }
  }

  // --------------------------------------------------------------------------
  // Root Schema Property Setters
  // --------------------------------------------------------------------------

  /// Validate, calculate and set the value of the 'allOf' JSON Schema prop.
  _setAllOf(dynamic value) => _validateListOfSchema('allOf', value, (schema) => _allOf.add(schema));

  /// Validate, calculate and set the value of the 'anyOf' JSON Schema prop.
  _setAnyOf(dynamic value) => _validateListOfSchema('anyOf', value, (schema) => _anyOf.add(schema));

  /// Validate, calculate and set the value of the 'defaultValue' JSON Schema prop.
  _setDefault(dynamic value) => _defaultValue = value;

  /// Validate, calculate and set the value of the 'definitions' JSON Schema prop.
  _setDefinitions(dynamic value) => (TypeValidators.object('definition', value))
      .forEach((k, v) => _makeSchema('$_path/definitions/$k', v, (rhs) => _definitions[k] = rhs));

  /// Validate, calculate and set the value of the 'description' JSON Schema prop.
  _setDescription(dynamic value) => _description = TypeValidators.string('description', value);

  /// Validate, calculate and set the value of the 'enum' JSON Schema prop.
  _setEnum(dynamic value) => _enumValues = TypeValidators.uniqueList('enum', value);

  /// Validate, calculate and set the value of the 'exclusiveMaximum' JSON Schema prop.
  _setExclusiveMaximum(dynamic value) => _exclusiveMaximum = TypeValidators.boolean('exclusiveMaximum', value);

  /// Validate, calculate and set the value of the 'exclusiveMinimum' JSON Schema prop.
  _setExclusiveMinimum(dynamic value) => _exclusiveMinimum = TypeValidators.boolean('exclusiveMinimum', value);

  /// Validate, calculate and set the value of the 'format' JSON Schema prop.
  _setFormat(dynamic value) => _format = TypeValidators.string('format', value);

  /// Validate, calculate and set the value of the 'id' JSON Schema prop.
  _setId(dynamic value) => _id = TypeValidators.uri('id', value);

  /// Validate, calculate and set the value of the 'minimum' JSON Schema prop.
  _setMinimum(dynamic value) => _minimum = TypeValidators.number('minimum', value);

  /// Validate, calculate and set the value of the 'maximum' JSON Schema prop.
  _setMaximum(dynamic value) => _maximum = TypeValidators.number('maximum', value);

  /// Validate, calculate and set the value of the 'maxLength' JSON Schema prop.
  _setMaxLength(dynamic value) => _maxLength = TypeValidators.nonNegativeInt('maxLength', value);

  /// Validate, calculate and set the value of the 'minLength' JSON Schema prop.
  _setMinLength(dynamic value) => _minLength = TypeValidators.nonNegativeInt('minLength', value);

  /// Validate, calculate and set the value of the 'multiple' JSON Schema prop.
  _setMultipleOf(dynamic value) => _multipleOf = TypeValidators.nonNegativeNum('multiple', value);

  /// Validate, calculate and set the value of the 'not' JSON Schema prop.
  _setNot(dynamic value) => _makeSchema('$_path/not', TypeValidators.object('not', value), (rhs) => _notSchema = rhs);

  /// Validate, calculate and set the value of the 'oneOf' JSON Schema prop.
  _setOneOf(dynamic value) => _validateListOfSchema('oneOf', value, (schema) => _oneOf.add(schema));

  /// Validate, calculate and set the value of the 'pattern' JSON Schema prop.
  _setPattern(dynamic value) => _pattern = new RegExp(TypeValidators.string('pattern', value));

  /// Validate, calculate and set the value of the 'ref' JSON Schema prop.
  _setRef(dynamic value) {
    _ref = TypeValidators.nonEmptyString(r'$ref', value);
    if (_ref[0] != '#') {
      final refSchemaFuture = createSchemaFromUrl(_ref).then((schema) => _addSchema(_ref, schema));

      /// Always add sub-schema retrieval requests to the [_root], as this is where the promise resolves.
      _root._retrievalRequests.add(refSchemaFuture);
    }
  }

  /// Validate the value of the 'schema' JSON Schema prop.
  ///
  /// This isn't stored because the schema version is always draft 4.
  _setSchema(dynamic value) => TypeValidators.jsonSchemaVersion4(r'$ref', value);

  /// Validate, calculate and set the value of the 'title' JSON Schema prop.
  _setTitle(dynamic value) => _title = TypeValidators.string('title', value);

  /// Validate, calculate and set the value of the 'type' JSON Schema prop.
  _setType(dynamic value) => _schemaTypeList = TypeValidators.schemaTypeList('type', value);

  // --------------------------------------------------------------------------
  // Schema List Item Related Property Setters
  // --------------------------------------------------------------------------

  /// Validate, calculate and set items of the 'pattern' JSON Schema prop that are also [JsonSchema]s.
  _setItems(dynamic value) {
    if (value is Map) {
      _makeSchema('$_path/items', value, (rhs) => _items = rhs);
    } else if (value is List) {
      int index = 0;
      _itemsList = new List(value.length);
      for (int i = 0; i < value.length; i++) {
        _makeSchema('$_path/items/${index++}', value[i], (rhs) => _itemsList[i] = rhs);
      }
    } else {
      throw FormatExceptions.error('items must be object or array: $value');
    }
  }

  /// Validate, calculate and set the value of the 'additionalItems' JSON Schema prop.
  _setAdditionalItems(dynamic value) {
    if (value is bool) {
      _additionalItems = value;
    } else if (value is Map) {
      _makeSchema('$_path/additionalItems', value, (rhs) => _additionalItems = rhs);
    } else {
      throw FormatExceptions.error('additionalItems must be boolean or object: $value');
    }
  }

  /// Validate, calculate and set the value of the 'maxItems' JSON Schema prop.
  _setMaxItems(dynamic value) => _maxItems = TypeValidators.nonNegativeInt('maxItems', value);

  /// Validate, calculate and set the value of the 'minItems' JSON Schema prop.
  _setMinItems(dynamic value) => _minItems = TypeValidators.nonNegativeInt('minItems', value);

  /// Validate, calculate and set the value of the 'uniqueItems' JSON Schema prop.
  _setUniqueItems(dynamic value) => _uniqueItems = TypeValidators.boolean('uniqueItems', value);

  // --------------------------------------------------------------------------
  // Schema Sub-Property Related Property Setters
  // --------------------------------------------------------------------------

  /// Validate, calculate and set sub-items or properties of the schema that are also [JsonSchema]s.
  _setProperties(dynamic value) => (TypeValidators.object('properties', value)).forEach((property, subSchema) =>
      _makeSchema('$_path/properties/$property', subSchema, (rhs) => _properties[property] = rhs));

  /// Validate, calculate and set the value of the 'additionalProperties' JSON Schema prop.
  _setAdditionalProperties(dynamic value) {
    if (value is bool) {
      _additionalProperties = value;
    } else if (value is Map) {
      _makeSchema('$_path/additionalProperties', value, (rhs) => _additionalPropertiesSchema = rhs);
    } else {
      throw FormatExceptions.error('additionalProperties must be a bool or valid schema object: $value');
    }
  }

  /// Validate, calculate and set the value of the 'dependencies' JSON Schema prop.
  _setDependencies(dynamic value) => (TypeValidators.object('dependencies', value)).forEach((k, v) {
        if (v is Map) {
          _makeSchema('$_path/dependencies/$k', v, (rhs) => _schemaDependencies[k] = rhs);
        } else if (v is List) {
          if (v.length == 0) throw FormatExceptions.error('property dependencies must be non-empty array');

          final Set uniqueDeps = new Set();
          v.forEach((propDep) {
            if (propDep is! String) throw FormatExceptions.string('propertyDependency', v);

            if (uniqueDeps.contains(propDep)) throw FormatExceptions.error('property dependencies must be unique: $v');

            _propertyDependencies.putIfAbsent(k, () => []).add(propDep);
            uniqueDeps.add(propDep);
          });
        } else {
          throw FormatExceptions.error('dependency values must be object or array: $v');
        }
      });

  /// Validate, calculate and set the value of the 'maxProperties' JSON Schema prop.
  _setMaxProperties(dynamic value) => _maxProperties = TypeValidators.nonNegativeInt('maxProperties', value);

  /// Validate, calculate and set the value of the 'minProperties' JSON Schema prop.
  _setMinProperties(dynamic value) => _minProperties = TypeValidators.nonNegativeInt('minProperties', value);

  /// Validate, calculate and set the value of the 'patternProperties' JSON Schema prop.
  _setPatternProperties(dynamic value) => (TypeValidators.object('patternProperties', value)).forEach(
      (k, v) => _makeSchema('$_path/patternProperties/$k', v, (rhs) => _patternProperties[new RegExp(k)] = rhs));

  /// Validate, calculate and set the value of the 'required' JSON Schema prop.
  _setRequired(dynamic value) => _requiredProperties = TypeValidators.nonEmptyList('required', value);
}
