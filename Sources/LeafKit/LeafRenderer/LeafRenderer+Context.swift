public extension LeafRenderer.Context {
    static func emptyContext(isRoot: Bool = false) -> Self { .init(isRootContext: isRoot) }
    
    /// Initialize a context with the given dictionary assigned to `self`
    init(_ context: [String: LeafDataRepresentable], isRoot: Bool = false) {
        self.isRootContext = isRoot
        try! setValues(to: context) }
    
    /// Initialize a context with the given dictionary literal assigned to `self`
    init(dictionaryLiteral elements: (String, LeafDataRepresentable)...) {
        self = .init(.init(uniqueKeysWithValues: elements)) }
    
    /// Initialize a context with the given dictionary literal assigned to `self`
    init(dictionaryLiteral elements: (String, LeafData)...) {
        self = .init(.init(uniqueKeysWithValues: elements)) }
    
    init?(encodable: [String: Encodable]) {
        let context = try? encodable.mapValues { e -> LeafDataRepresentable in
            let encoder = LKEncoder()
            try e.encode(to: encoder)
            return encoder
        }
        guard context != nil else { return nil }
        self.init(context!)
    }
    
    init?(encodable asSelf: Encodable) {
        let encoder = LKEncoder()
        guard (try? asSelf.encode(to: encoder)) != nil,
              let dict = encoder.root?.leafData.dictionary else { return nil }
        self.init(dict)
    }
    
    
    static var defaultContextScope: String { LKVariable.selfScope }
    
    /// Set the contextual values for a specific valid scope, overwriting if any exist.
    ///
    /// If scope already exists as a literal but LeafKit is running, update will fail. Will initialize context
    /// scope if it does not already exist.
    mutating func setValues(for scope: String = defaultContextScope,
                            to values: [String: LeafDataRepresentable],
                            allLiteral: Bool = false) throws {
        if allLiteral { try literalGuard() }
        if scope == LKVariable.selfScope && allLiteral { throw err("`self` cannot be constant") }
        let scopeVar = try getScopeKey(scope)
        let constantScope = contexts[scopeVar]?.literal ?? false
        if constantScope {
            guard !LKConf.isRunning else {
                throw err("\(scope) is a constant scoped context and cannot be updated") }
            assert(allLiteral,
                   "\(scope) already exists as a constant scope - setting values is implicitly constant")
        }
        if contexts[scopeVar] == nil {
            contexts[scopeVar] = .init(parent: scopeVar, literal: allLiteral) }
        contexts[scopeVar]!.setValues(values, allLiteral: allLiteral)
    }
    
    /// Set a specific value (eg `$app.variableName`) where scope == "app" and id = "variableName"
    ///
    /// If the value is already set, will overwrite the existing value (unless the value or its scope is
    /// globally literal *and* LeafKit is already running; literal values may be updated freely prior
    /// to LeafKit starting)
    mutating func setVariable(in scope: String = defaultContextScope,
                              for id: String,
                              to value: LeafDataRepresentable,
                              isLiteral: Bool = false) throws {
        if isLiteral { try literalGuard() }
        guard id.isValidLeafIdentifier else { throw err(.invalidIdentifier(id)) }
        try setValue(in: scope, at: id, to: value, isLiteral: isLiteral)
    }
        
    /// Set a specific value (eg `$app[key]`) to new value; follows same rules as `setVariable`
    ///
    /// `setVariable` is to be preferred as it ensures the identifier is a valid key. While keys that
    /// are valid variable names will be published to Leaf (eg, `$app.id`), invalid identifiers will only
    /// be accessible by subscripting.
    ///
    /// If the value is already set, will overwrite the existing value (unless the value or its scope is
    /// globally constant *and* LeafKit is already running; literal values may be updated freely prior
    /// to LeafKit starting with the caveat that, once declared or locked as literal, it may no longer be
    /// reverted to a variable)
    mutating func setValue(in scope: String = defaultContextScope,
                           at key: String,
                           to value: LeafDataRepresentable,
                           isLiteral: Bool = false) throws {
        if isLiteral { try literalGuard() }
        guard !key.isEmpty else { throw err("Value key must not be empty string") }
        let scopeVar = try getScopeKey(scope)
        guard isUpdateable(scopeVar, key) else { throw err("\(scope)[\(key)] is not settable") }
        if let isVariable = contexts[scopeVar]?[key]?.isVariable, !isVariable && !isLiteral {
            throw err("\(scope)[\(key)] was already declared as constant - cannot change to variable")
        }
        self[scopeVar, key] = isLiteral ? .literal(value.leafData) : .variable(value)
    }
    
    /// Update an already existing value and maintain its variable/literal state
    mutating func updateValue(in scope: String = defaultContextScope,
                              at key: String,
                              to value: LeafDataRepresentable) throws {
        let scopeVar = try validateScope(scope)
        guard let isVariable = contexts[scopeVar]![key]?.isVariable else {
            throw err("Value must already be set to update") }
        guard isVariable || !LKConf.isRunning else {
            throw err("Constant context values cannot be updated after LeafKit starts") }
        contexts[scopeVar]![key] = isVariable ? .variable(value) : .literal(value)
    }
    
    /// Lock an existing value as globally literal
    mutating func lockAsLiteral(key: String,
                                in scope: String = defaultContextScope) throws {
        try literalGuard()
        let scopeVar = try validateScope(scope)
        if contexts[scopeVar]![key] == nil { throw nonExistant(scope, key) }
        contexts[scopeVar]!.setLiteral(key)
    }
    
    /// Lock an entire existing scope and all its contained values as globally literal
    mutating func lockAsLiteral(scope: String) throws {
        try literalGuard()
        let scopeVar = try validateScope(scope)
        contexts[scopeVar]!.setLiteral()
    }
    
    /// Cache the current value of `leafData` in context for an existing key
    ///
    /// Only applicable for variable values; locking a scope or value as literal, or declaring as such,
    /// inherently caches the value
    mutating func cacheValue(in scope: String = defaultContextScope,
                             at key: String) throws {
        let scopeVar = try validateScope(scope)
        if contexts[scopeVar]![key] == nil { throw nonExistant(scope, key) }
        contexts[scopeVar]![key]!.refresh()
    }
    
    /// Register a Swift object to the context.
    ///
    /// `type: ObjectMode` specifies what ways the object is registered to the context; one or both of:
    ///  * As a context publishing object (must adhere to either `LeafContextPublisher` [preferred] or
    ///     `LeafDataRepresentable` resolving to `LeafData.dictionary`).
    ///  * As a raw object that `LeafUnsafeEntity` objects will have access to during serializing.
    ///
    /// In both cases, `key` represents the access method - for contextual objects, the values it registers
    /// will be published as variables under `$key` scope in Leaf, and for unsafe objects, tags with access
    /// will have `externalObjects[key]` access to the exact object.
    mutating func register(object: Any?,
                           as key: String,
                           type: ObjectMode = .contextual) throws {
        assert(type.rawValue != 0, "Registering objects must have at least one mode set")
        if object != nil, object is AnyClass {
            preconditionFailure("Reference types are not currently supported") }
        if type.contains(.unsafe) || object == nil { externalObjects[key] = object }
        if type.contains(.contextual) && object == nil,
           let scope = try? validateScope(key) {
            defer { contexts[scope] = nil; checkLiterals() }
            guard LKConf.isRunning else { return }
            guard let ctx = contexts[scope], !ctx.literal else {
                throw err("\(key) is a literal scope - cannot be unset") }
            guard ctx.values.allSatisfy({$0.value.isVariable}) else {
                throw err("\(key) has literal values - cannot be unset") }
        } else if type.contains(.contextual), key.isValidLeafIdentifier, let object = object {
            if let c = object as? LeafContextPublisher {
                let values = c.coreVariables.merging(c.extendedVariables) {_, b in b}
                try setValues(for: key, to: values.mapValues { $0.container })
            }
            else if let data = (object as? LeafDataRepresentable)?.leafData.dictionary {
                try setValues(for: key, to: data) }
            else { assertionFailure("A registered external object must be either `LeafContextPublisher` or `LeafDataRepresentable` vending a dictionary when `type` contains `.contextual`") }
        }
    }
    
    /// Overlay & merge the values of a second context onto a base one.
    ///
    /// When stacking multiple contexts, only a root context may contain literals, so overlaying any
    /// additional context values must be entirely variable (and if conflicts occur in a value where the
    /// underlaying context holds a literal value, will error).
    mutating func overlay(_ secondary: Self) throws {
        guard !secondary.isRootContext else { throw err("Can only overlay non-root contexts") }
        secondary.externalObjects.forEach { externalObjects[$0] = $1 }
        try secondary.contexts.forEach { k, v in
            if contexts[k] == nil { contexts[k] = v }
            else {
                for key in v.values.keys {
                    if !(contexts[k]![key]?.isVariable ?? true) {
                        throw err("\(k.extend(with: key).terse) is literal in underlaying context; can't override") }
                    contexts[k]![key] = v[key]
                }
            }
        }
    }
}

internal extension LeafRenderer.Context {
    /// For complicated objects being passed in context to Leaf that may have expensive calculation, generators
    /// are preferred as they will only be accessed and calculated if the template actually uses the variable.
    ///
    /// No option for setting as `literal` because doing so is functionally pointless - literal values are always
    /// flattened globally, so there's no benefit to doing it unless usage dictates the values will not change.
    mutating func setLazyValues(in scope: String = defaultContextScope,
                                to generators: [String: LeafDataRepresentable]) throws {
        try setValues(for: scope,
                      to: generators.mapValues { v in LeafData.lazy({v.leafData},
                                                                    returns: .void) })
    }
    
    /// All scope & scoped atomic variables defined by the context
    var allVariables: Set<LKVariable> { contexts.values.reduce(into: []) {$0.formUnion($1.allVariables)} }
    
    /// Return a filtered version of the context that holds only literal values for parse stage
    var literalsOnly: Self {
        guard isRootContext else { return .init(isRootContext: false) }
        var contexts = self.contexts
        for (scope, context) in contexts {
            if context.literal { continue }
            context.values.forEach { k, v in if v.isVariable { contexts[scope]![k] = nil } }
            if contexts[scope]!.values.isEmpty { contexts[scope] = nil }
        }
        return .init(isRootContext: true, contexts: contexts)
    }
    
    mutating func literalGuard() throws {
        guard isRootContext else { throw err("Cannot set literal values on non-root context") }
        anyLiteral = true
    }
    
    /// Helper error generator
    func nonExistant(_ scope: String, _ key: String? = nil) -> LeafError {
        err("\(scope)\(key != nil ? "[\(key!)]" : "") does not exist in context") }
    
    func validateScope(_ scope: String) throws -> LKVariable {
        let scopeVar = try getScopeKey(scope)
        guard contexts[scopeVar] != nil else { throw err("\(scopeVar) does not exist in context") }
        return scopeVar
    }
    
    func getScopeKey(_ scope: String) throws -> LKVariable {
        guard scope.isValidLeafIdentifier else { throw err(.invalidIdentifier(scope)) }
        return .scope(scope)
    }
    
    /// If a given scope/key in the context is updatable (variable or literal prior to running)
    func isUpdateable(_ scope: LKVariable, _ key: String) -> Bool {
        if contexts[scope]?.frozen ?? false { return false }
        if contexts[scope]?.literal ?? false && LKConf.isRunning { return false }
        return self[scope, key]?.isVariable ?? true || !LKConf.isRunning
    }
    
    /// Directly retrieve single value from a context by LKVariable; only use when user can no longer edit structure.
    mutating func get(_ key: LKVariable) -> LeafData? {
        contexts[.scope(key.scope!)]?.match(key) }
    
    /// Generally not needed as `anyLiteral` sets when literals are set, but unsetting objects may remove that
    mutating func checkLiterals() { anyLiteral = !literalsOnly.contexts.isEmpty }
    
    subscript(_ scope: LKVariable, _ variable: String) -> LKDataValue? {
        get { contexts[scope]?[variable] }
        set {
            if contexts[scope] == nil { contexts[scope] = .init(parent: scope) }
            contexts[scope]![variable] = newValue
        }
    }
        
    var timeout: Double {
        if case .timeout(let b) = options?[.timeout] { return b }
        else { return Self.timeout } }
    var missingVariableThrows: Bool {
        if case .missingVariableThrows(let b) = options?[.missingVariableThrows] { return b }
        else { return Self.missingVariableThrows } }
    var grantUnsafeEntityAccess: Bool {
        if case .grantUnsafeEntityAccess(let b) = options?[.grantUnsafeEntityAccess] { return b }
        else { return Self.grantUnsafeEntityAccess } }
    var cacheBypass: Bool {
        if case .cacheBypass(let b) = options?[.cacheBypass] { return b }
        else { return Self.cacheBypass } }
}