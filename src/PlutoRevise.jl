module PlutoRevise
    using CodeTracking
    using Revise
    using HypertextLiteral
    using AbstractPlutoDingetjes
    import Pkg
    import TOML
    using AbstractPlutoDingetjes.Display: Display, with_js_link, published_to_js
    using ScopedSettings: ScopedSettings, ScopedSetting, @with, with

    const DEFAULT_IO = ScopedSetting{IO}(devnull)
    const PROJECT_ROOT = Ref{String}()
    const LOADED_MODULES_NAME = :_PlutoReviseModules_
    const STDLIBS_IDS = Dict((
        let (name, info) = pair
            info.name => Base.PkgId(info.uuid, info.name)
        end
        for pair in Pkg.Types.stdlib_infos()
    ))
    const PKGNAME = ScopedSetting{String}("")
    const CELL_TO_PACKAGE = Dict{Base.UUID, Module}()

    include("import_helpers.jl")
    include("html_button.jl")

    latest_workspace_count() = return Main.PlutoRunner.moduleworkspace_count[]

    function latest_pluto_module()
        id = latest_workspace_count()
        new_workspace_name = Symbol("workspace#", id)
        getproperty(Main, new_workspace_name)
    end

    macro fromenv(ex)
        return process_import_statement(ex) |> esc
    end

    is_stdlib(pkg_name::AbstractString) = return haskey(STDLIBS_IDS, pkg_name)

    function default_plutorevise_env()
        active_proj = Base.active_project()
        contains(active_proj, "c3e4b0f8-55cb-11ea-2926-15256bba5781/pkg_envs") || error("The default PlutoRevise environment requires a notebook handled by PlutoPkg and with a Pluto version greater than 0.20.18")
        joinpath(dirname(active_proj), "plutorevise_env")
    end

    project_root() = return isassigned(PROJECT_ROOT) ? PROJECT_ROOT[] : project_root(default_plutorevise_env())

    function project_root(new_env::String)
        if isassigned(PROJECT_ROOT) && PROJECT_ROOT[] != new_env
            old_env = PROJECT_ROOT[]
            li = findfirst(==(old_env), LOAD_PATH)
            isnothing(li) || deleteat!(LOAD_PATH, li) # We delete the old
        end
        findfirst(==(new_env), LOAD_PATH) === nothing && push!(LOAD_PATH, new_env)
        return PROJECT_ROOT[] = new_env
    end

    function on_project(f; io = DEFAULT_IO[])
        current_project = Base.active_project()
        try
            Pkg.activate(project_root(); io)
            f()
        finally
            Pkg.activate(current_project; io)
        end
    end

    function develop(path::AbstractString; kwargs...)
        on_project() do
            Pkg.develop(;path, io = DEFAULT_IO[], kwargs...)
        end
    end

    macro imp(pkg_name::Symbol)
        quote
            $load_from_env($(QuoteNode(pkg_name)))
            import Main.$(LOADED_MODULES_NAME).$(pkg_name)
        end
    end

    macro use(pkg_name::Symbol)
        quote
            $load_from_env($(QuoteNode(pkg_name)))
            using Main.$(LOADED_MODULES_NAME).$(pkg_name)
        end
    end

    # This function will load a package from the PlutoRevise project into the Main._PlutoReviseModules_
    function load_from_env(pkg_name::Symbol)
        name_str = String(pkg_name)
        pm = if isdefined(Main, LOADED_MODULES_NAME)
            getglobal(Main, LOADED_MODULES_NAME)
        else
            Core.eval(Main, :(module $LOADED_MODULES_NAME end))
            invokelatest(getglobal, Main, LOADED_MODULES_NAME)
        end
        isdefined(pm, pkg_name) && return  # already loaded
        @info "Trying to load the requested package $name_str"
        manifest_deps = get_manifest_deps()
        if is_stdlib(name_str)
            id = STDLIBS_IDS[name_str]
            @eval pm import $pkg_name
        else
            info = get(manifest_deps, name_str) do
                throw(ArgumentError("Package $name_str is not a stdlib nor a dependency of the custom environment"))
            end
            id = info.id
            if haskey(Base.loaded_modules, id)
                mod = Base.loaded_modules[id]
                @eval pm const $pkg_name = $mod
            elseif info.direct
                @eval pm import $pkg_name
            else
                fill_modpaths!(manifest_deps)
                error("The package $name_str is not loaded in the current Julia session.")
            end
        end
        invokelatest(getproperty, pm, pkg_name)
    end

    function get_manifest_deps(proj_dir::AbstractString = project_root())
        manifest_file = joinpath(proj_dir, "Manifest.toml")
        toml = TOML.parsefile(manifest_file)
        deps = Dict{String, Any}()
        direct_deps = get_direct_deps(proj_dir)
        for (key, value) in toml["deps"]
            dict = first(value)
            uuid = Base.UUID(dict["uuid"])
            version = VersionNumber(get(dict,"version", "0"))
            id = Base.PkgId(uuid, key)
            stdlib = haskey(STDLIBS_IDS, key)
            name = key
            direct = name in direct_deps
            modpath = (direct || stdlib) ? [name] : String[]
            deps[key] = (; id, version, uuid, name, direct, stdlib, deps = get(dict, "deps", String[]), modpath)
        end
        return deps
    end

    function fill_modpaths!(dict = get_manifest_deps(), direct_deps = get_direct_deps(), parent_modpath = String[])
        for dep in direct_deps
            nt = dict[dep]
            should_fill = isempty(nt.modpath)
            should_recurse = should_fill || (length(nt.modpath) == 1 && !nt.stdlib)
            if should_fill
                copy!(nt.modpath, parent_modpath)
                push!(nt.modpath, nt.name)
            end
            should_recurse && fill_modpaths!(dict, nt.deps, nt.modpath)
        end
        return dict
    end

    function get_direct_deps(proj_dir::AbstractString = project_root())
        proj_file = joinpath(proj_dir, "Project.toml")
        proj_toml = TOML.parsefile(proj_file)
        pkgname = get(proj_toml, "name", "")
        return isempty(pkgname) ? keys(proj_toml["deps"]) : [pkgname, keys(proj_toml["deps"])...]
    end

    function force_cell_rerun(cell_id::Base.UUID; soft = false)
        if !soft # We do a hard rerun, also recomputing macro expansion
            pop!(Main.PlutoRunner.cell_expanded_exprs, cell_id) # We remove the cached expanded expr
            computer = pop!(Main.PlutoRunner.computers, cell_id, nothing) # We try removing the computer for this cell if present
            if !isnothing(computer) # We also do some cleanup if we had a computer
                Main.PlutoRunner.UseEffectCleanups.trigger_cleanup(cell_id)
                Base.delete_method(methods(computer.f) |> only) # Make the computer function uncallable
            end
        end
        Main.PlutoRunner.rerun_cell_from_notebook(cell_id) # Trigger the re-run
    end
    force_cell_rerun(uuid::String) = force_cell_rerun(Base.UUID(uuid))

    function file_uuid(plutopath::String)
        out = split(plutopath, "#==#")
        length(out) == 1 && return first(out), ""
        return out[1], out[2]
    end
    file_uuid(plutopath::Symbol) = file_uuid(String(plutopath))


    function find_parent_package(path::AbstractString)
        proj = Base.current_project(path)
        env = dirname(proj)
        toml = TOML.parsefile(proj)
        haskey(toml, "name") || error("The closest parent enviroment $(env) is not a package")
        return env, toml["name"]
    end

    macro fromparent(ex)
        file, uuid = file_uuid(__source__.file)
        parent_pkg, pkg_name = find_parent_package(file)
        project_root(parent_pkg)
        out = Expr(:block)
        @with PKGNAME => pkg_name begin
            push!(out.args, process_import_statement(ex))
            push!(out.args, :($CELL_TO_PACKAGE[$(Base.UUID(uuid))] = $(esc(Symbol(pkg_name)))))
            push!(out.args, :($html_reload_button($uuid; name=$pkg_name)))
        end
        return out
    end

end # module PlutoRevise
