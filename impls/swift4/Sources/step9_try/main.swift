
import Foundation

func READ(_ input: String) throws -> MalData {
    return try read_str(input)
}

func EVAL(_ anAst: MalData, env anEnv: Env) throws -> MalData {
    func is_pair(_ ast: MalData) -> Bool { // not used
        return (ast is [MalData]) && (ast.count != 0)
    }
    func quasiquote(_ ast: MalData) -> MalData {
        let list = ast.listForm
        if list.isEmpty {
            return [Symbol("quote"), ast]
        }
        if let sym = list[0] as? Symbol, sym.name == "unquote" {
            return list[1]
        }
        let innerList = list[0].listForm
        if !innerList.isEmpty, let sym = innerList[0] as? Symbol, sym.name == "splice-unquote" {
            return [Symbol("concat"), innerList[1], quasiquote(list.dropFirst().listForm)]
        }
        return [Symbol("cons"), quasiquote(list[0]), quasiquote(list.dropFirst().listForm)]
    }
    func macroexpand(_ anAst: MalData, env: Env) throws -> MalData {
        func isMacro_call(_ ast: MalData, env: Env) -> Bool { // not used
            if let list = ast as? [MalData],
                let symbol = list[0] as? Symbol,
                let fn = try? env.get(forKey: symbol) as? Function {
                return fn?.isMacro ?? false
            }
            return false
        }
        
        var ast = anAst
        while let list = ast as? [MalData],
            let symbol = list[0] as? Symbol,
            let fn = try? env.get(forKey: symbol) as? Function,
            let isMacro = fn?.isMacro, isMacro == true {
                ast = try fn!.fn(List(list.dropFirst()))
        }
        return ast
    }
    
    /// Apply
    var ast = anAst, env = anEnv
    while true {
        switch ast.dataType {
        case .List:
            if (ast as! [MalData]).isEmpty { return ast }
            ast = try macroexpand(ast, env: env)
            guard let list = ast as? [MalData] else { return try eval_ast(ast, env: env) }
            guard !list.isEmpty else { return list }
            if let sym = list[0] as? Symbol {
                switch sym.name {
                case "def!":
                    let value = try EVAL(list[2], env: env), key = list[1] as! Symbol
                    env.set(value, forKey: key)
                    return value
                case "defmacro!":
                    let fn = try EVAL(list[2], env: env) as! Function, key = list[1] as! Symbol
                    let macro = Function(withFunction: fn, isMacro: true)
                    env.set(macro, forKey: key)
                    return macro
                case "let*":
                    let newEnv = Env(outer: env), expr = list[2]
                    let bindings = list[1].listForm
                    for i in stride(from: 0, to: bindings.count-1, by: 2) {
                        let key = bindings[i], value = bindings[i+1]
                        let result = try EVAL(value, env: newEnv)
                        newEnv.set(result, forKey: key as! Symbol)
                    }
                    env = newEnv
                    ast = expr
                    continue
                case "do":
                    try _ = list.dropFirst().dropLast().map { try EVAL($0, env: env) }
                    ast = list.last ?? Nil()
                    continue
                case "if":
                    let predicate = try EVAL(list[1], env: env)
                    if predicate as? Bool == false || predicate is Nil {
                        ast = list.count>3 ? list[3] : Nil()
                    } else {
                        ast = list[2]
                    }
                    continue
                case "fn*":
                    let fn = {(params: [MalData]) -> MalData in
                        let newEnv = Env(binds: (list[1].listForm as! [Symbol]), exprs: params, outer: env)
                        return try EVAL(list[2], env: newEnv)
                    }
                    return Function(ast: list[2], params: (list[1].listForm as! [Symbol]), env:env , fn: fn)
                case "quote":
                    return list[1]
                case "quasiquote":
                    ast = quasiquote(list[1])
                    continue
                case "macroexpand":
                    return try macroexpand(list[1], env: env)
                case "try*":
                    do {
                        return try EVAL(list[1], env: env)
                    } catch let error as MalError {
                        if list.count > 2 {
                            let catchList = list[2] as! [MalData]
                            let catchEnv = Env(binds: [catchList[1] as! Symbol], exprs:[error.info()] , outer: env)
                            return try EVAL(catchList[2], env: catchEnv)
                        } else {
                            throw error
                        }
                    }
                default:
                    break
                }
            }
            // not a symbol. maybe: function, list, or some wrong type
            let evaluated = try eval_ast(list, env: env) as! [MalData]
            guard let function = evaluated[0] as? Function else {
                throw MalError.SymbolNotFound(list[0] as? Symbol ?? Symbol("Symbol"))
            }
            if let fnAst = function.ast { // a full fn
                ast = fnAst
                env = Env(binds: function.params!, exprs: evaluated.dropFirst().listForm, outer: function.env!)
            } else { // normal function
                return try function.fn(evaluated.dropFirst().listForm)
            }
            continue
        case .Vector:
            let vector = ast as! ContiguousArray<MalData>
            return try ContiguousArray(vector.map { element in try EVAL(element, env: env) })
        case .HashMap:
            let hashMap = ast as! HashMap<String, MalData>
            return try hashMap.mapValues { value in try EVAL(value, env: env) }
        default:
            return try eval_ast(ast, env: env)
        }
    }
}

func PRINT(_ input: MalData) -> String {
    return pr_str(input, print_readably: true)
}

@discardableResult func rep(_ input: String, env: Env) throws -> String {
    return try PRINT(EVAL(READ(input), env: env))
}

func eval_ast(_ ast: MalData, env: Env) throws -> MalData {
    switch ast.dataType {
    case .Symbol:
        let sym = ast as! Symbol
        if let function =  try? env.get(forKey: sym) {
            return function
        } else {
            throw MalError.SymbolNotFound(sym)
        }
    case .List:
        let list = ast as! [MalData]
        return try list.map { element in try EVAL(element, env: env) }
    case .Atom:
        return (ast as! Atom).value
    default:
        return ast
    }
}



var repl_env = Env()
for (key, value) in ns {
    repl_env.set(Function(fn: value), forKey: Symbol(key))
}
repl_env.set(Function(fn: { try EVAL($0[0], env: repl_env) }), forKey: Symbol("eval"))
repl_env.set([], forKey: Symbol("*ARGV*"))

try rep("(def! not (fn* (a) (if a false true)))", env: repl_env)
try rep("(def! load-file (fn* (f) (eval (read-string (str \"(do \" (slurp f) \"\nnil)\")))))", env: repl_env)
try rep("(defmacro! cond (fn* (& xs) (if (> (count xs) 0) (list 'if (first xs) (if (> (count xs) 1) (nth xs 1) (throw \"odd number of forms to cond\")) (cons 'cond (rest (rest xs)))))))", env: repl_env)

if CommandLine.argc > 1 {
    let fileName = CommandLine.arguments[1],
        args     = List(CommandLine.arguments.dropFirst(2))
    repl_env.set(args, forKey: Symbol("*ARGV*"))
    try rep("(load-file \"\(fileName)\")", env: repl_env)
    exit(0)
}

while true {
    print("user> ", terminator: "")
    if let input = readLine(strippingNewline: true) {
        guard input != "" else { continue }
        do {
            try print(rep(input, env: repl_env))
        } catch MalError.MalException(let data) {
            if let description = data as? String {
                print("Exception." + description)
            } else if let dic = data as? [String: String], !dic.isEmpty {
                print("Exception." + dic.keys.first! + "." + dic.values.first!)
            }
        } catch let error as MalError {
            print((pr_str(error.info(), print_readably: false)))
        }
    } else {
        exit(0);
    }
}
