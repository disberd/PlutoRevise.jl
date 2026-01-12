mutable struct ImportAs
    original::Vector{Symbol}
    as::Union{Symbol,Nothing}
end
ImportAs(nm::Symbol) = ImportAs([nm], nothing)
function ImportAs(original::Vector)
    @assert all(nm -> isa(nm, Symbol), original) "Only vectors containing just symbols are valid inputs to the ImportAs constructor."
    ImportAs(Symbol.(original), nothing)
end
function ImportAs(ex::Expr)
    if ex.head === :.
        ImportAs(ex.args)
    elseif ex.head === :as
        as = last(ex.args)
        original = first(ex.args).args
        ImportAs(original, as)
    else
        error("The provided expression is not valid for constructing ImportAs.\nOnly `:.` and `:as` are supported as expression head.")
    end
end

function reconstruct_import_statement(ia::ImportAs)
    ex = Expr(:., ia.original...)
    if ia.as !== nothing
        ex = Expr(:as, ex, ia.as)
    end
    return ex
end

abstract type ImportData end

mutable struct ModuleWithNames <: ImportData
    head::Symbol
    modname::ImportAs
    imported::Vector{ImportAs}
end
function ModuleWithNames(ex::Expr)
    args = ex.args
    is_valid = Meta.isexpr(ex, (:using, :import)) && length(args) == 1 && Meta.isexpr(first(args), :(:))
    @assert is_valid "Only import/using expression with an explicit list of imported names are valid inputs to the ModuleWithNames constructor."
    # We extract the :(:) expression
    args = first(args).args
    # The first arg is the module
    modname = ImportAs(first(args))
    # The remaining args are the imported names
    imported = map(ImportAs, args[2:end])
    ModuleWithNames(ex.head, modname, imported)
end
function reconstruct_import_statement(mwn::ModuleWithNames; head=mwn.head)
    inner_expr = Expr(:(:), reconstruct_import_statement(mwn.modname), map(reconstruct_import_statement, mwn.imported)...)
    Expr(head, inner_expr)
end

mutable struct JustModules <: ImportData
    head::Symbol
    modnames::Vector{ImportAs}
end
function JustModules(ex::Expr)
    args = ex.args
    is_valid = Meta.isexpr(ex, (:using, :import)) && all(x -> Meta.isexpr(x, (:., :as)), args)
    @assert is_valid "Only import/using expression with multiple imported/used modules are valid inputs to the JustModules constructor."
    JustModules(ex.head, map(ImportAs, args))
end
function reconstruct_import_statement(jm::JustModules)
    Expr(jm.head, map(reconstruct_import_statement, jm.modnames)...)
end
# This is used to reconstruct a mwn with empty import list
function JustModules(mwn::ModuleWithNames)
    @assert isempty(mwn.imported) "You can only construct a JustModules object with a ModuleWithNames object with an empty import list."
    JustModules(mwn.head, [mwn.modname])
end


function extract_import_data(ex::Expr)
    @assert Meta.isexpr(ex, (:using, :import)) "You can only use import or using expression as input to the `extract_import_data` function."
    id = if Meta.isexpr(first(ex.args), :(:))
        ModuleWithNames(ex)
    else
        JustModules(ex)
    end
    return id
end

iterate_imports(mwn::ModuleWithNames) = [mwn]
function iterate_imports(jm::JustModules)
    f(modname::ImportAs) = ModuleWithNames(jm.head, modname, Symbol[])
    map(f, jm.modnames)
end
iterate_imports(ex::Expr) = extract_import_data(ex) |> iterate_imports

function filterednames_filter_func(caller_module)
    excluded = (:eval, :include, :__init__)
    f(s)::Bool =
        let excluded = excluded, caller_module = caller_module
            Base.isgensym(s) && return false
            s in excluded && return false
            isdefined(caller_module, s) && return which(caller_module, s) ∉ (Base, Core, Main)
            return true
        end
    return f
end

function isimported(modname::Symbol)
    modname === :Main && return true
    _, loaded = fastload_from_env(modname)
    return loaded
end


function process_import_statement!(outs, ex::Expr, calling_module = latest_pluto_module(); prerun = nothing)
    (; modnames, exprs) = outs
    prerun = @something prerun any(!isimported, modnames)
    for isd in iterate_imports(ex)
        root = process_modpath!(isd)
        push!(modnames, root)
        prerun = prerun || !isimported(root)
        if !prerun
            ex = complete_imported_names!(isd, calling_module)
            push!(exprs, ex)
        end
    end
    return prerun
end

# This function will generate an importa statement by expanding the modname_path to the correct path based on the provided `starting_module`. It will also expand imported names if a catchall expression is found
function process_import_statement(ex::Expr, calling_module = latest_pluto_module())
    # Extract the import statement data
    block = quote end
    modnames = Set{Symbol}()
    exprs = Expr[]
    outs = (; modnames, exprs)
    prerun = false
    if Meta.isexpr(ex, :block)
        for subex in ex.args
            subex isa Expr || continue
            prerun = process_import_statement!(outs, subex, calling_module; prerun)
        end
    else
        prerun = process_import_statement!(outs, ex, calling_module; prerun)
    end
    if prerun
        # We just put the loading button
        link_func = temp_load_function(modnames)
        push!(block.args, :($html_loading_button($link_func)))
    else
        copy!(block.args, exprs)
    end
    return block, prerun
end

function process_modpath!(mwn::ModuleWithNames)
    path = mwn.modname.original
    root = popfirst!(path)
    root === :_ || error("All import statements must start with `_`")
    if isempty(path)
        pkgname = PKGNAME[]
        isempty(pkgname) && error("You can't simply use `_` on an environment that is not a package")
        pushfirst!(path, Symbol(pkgname))
    end
    root = first(path) # We now extract the useful name of the first module
    pushfirst!(path, :Main, LOADED_MODULES_NAME)
    return root
end

# This function traverse a path to access a nested module from a `starting_module`. It is used to extract the corresponding module from `import/using` statements.
function extract_nested_module(starting_module::Module, nested_path; first_dot_skipped=false)
    m = starting_module
    for name in nested_path
        m = if name === :.
            first_dot_skipped ? parentmodule(m) : m
        else
            @assert invokelatest(isdefined, m, name) "The module `$name` could not be found inside parent module `$(nameof(m))`"
            invokelatest(getproperty, m, name)::Module
        end
        first_dot_skipped = true
    end
    return m
end

# This will modify the import statements provided as input to `@frompackage` by updating the modname_path and eventually extracting exported names from the module and explicitly import them. It will also transform each statement into using explicit imported names (even for simple imports) are import/using without explicit names are currently somehow broken in Pluto if not handled by the PkgManager
function complete_imported_names!(mwn::ModuleWithNames, calling_module = latest_pluto_module())::Expr
    if !isempty(mwn.imported)
        # If we already have an explicit list of imports, we do not modify and simply return the corresponding expression
        # Here we do not modify the list of explicitily imported names, as it's better to get an error if you explicitly import something that was already defined in the notebook
        return reconstruct_import_statement(mwn; head=:import)
    end
    nested_path = mwn.modname.original
    m = extract_nested_module(Main, nested_path)
    # if catchall
    #     # We extract all the names, potentially include usings encountered
    #     return catchall_import_expression!(mwn, p, m; exclude_usings)
    # else
        if mwn.head === :import
            # We explicitly import the module itself
            modname = mwn.modname
            import_as = ImportAs(nameof(m))
            as = modname.as
            if as !== nothing
                # We remove the `as` from the module name expression
                modname.as = nothing
                # We add it to the imported name
                import_as.as = as
            end
            push!(mwn.imported, import_as)
        else
            # We export the names exported by the module
            mwn.imported = names(m) .|> ImportAs
        end
    # end
    # We have to filter the imported names to exclude ones that are already defined in the caller
    filter_func = filterednames_filter_func(calling_module)
    filter!(mwn.imported) do import_as
        as = import_as.as
        imported_name = something(as, last(import_as.original))
        isdefined(m, imported_name) || return false
        return filter_func(imported_name)
    end
    # The list of imported names should be empty only when inner=false
    ex = reconstruct_import_statement(mwn; head=:import)
    return ex
end