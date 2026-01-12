module PlutoRevise
    using CodeTracking
    using Revise
    using HypertextLiteral
    using AbstractPlutoDingetjes
    import Pkg
    import TOML
    using AbstractPlutoDingetjes.Display: Display, with_js_link, published_to_js
    using ScopedSettings

    const DEFAULT_IO = ScopedSetting{IO}(devnull)
    const PROJECT_ROOT = Ref{String}()
    const LOADED_MODULES_NAME = :_PlutoReviseModules_
    const STDLIBS_IDS = Dict((
        let (name, info) = pair
            info.name => Base.PkgId(info.uuid, info.name)
        end
        for pair in Pkg.Types.stdlib_infos()
    ))

    is_stdlib(pkg_name::AbstractString) = return haskey(STDLIBS_IDS, pkg_name)

    function get_project_root()
        if !isassigned(PROJECT_ROOT)
            active_proj = Base.active_project()
            contains(active_proj, "c3e4b0f8-55cb-11ea-2926-15256bba5781/pkg_envs") || error("The PlutoRevise package requires a notebook handled by PlutoPkg and with a Pluto version greater than 0.20.18")
            PROJECT_ROOT[] = joinpath(dirname(active_proj), "plutorevise_env")
        end
        return PROJECT_ROOT[]
    end

    function check_loadpath()
        proj = get_project_root()
        proj in LOAD_PATH || push!(LOAD_PATH, proj)
        return nothing
    end

    function on_project(f; io = DEFAULT_IO[])
        current_project = Base.active_project()
        try
            Pkg.activate(get_project_root(); io)
            f()
            check_loadpath()
        finally
            Pkg.activate(current_project; io)
        end
    end

    function develop(path::AbstractString; kwargs...)
        on_project() do
            Pkg.develop(;path, io = DEFAULT_IO[], kwargs...)
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
                error("The package $name_str is not loaded in the current Julia session.\nTry loading the direct dependency `$(first(info.modpath))` that includes it in the manifest.")
            end
        end
        invokelatest(getproperty, pm, pkg_name)
    end

    function get_manifest_deps(proj_dir::AbstractString = get_project_root())
        manifest_file = joinpath(proj_dir, "Manifest.toml")
        toml = TOML.parsefile(manifest_file)
        deps = Dict{String, Any}()
        direct_deps = get_direct_deps(proj_dir)
        for (key, value) in toml["deps"]
            dict = first(value)
            uuid = Base.UUID(dict["uuid"])
            version = VersionNumber(dict["version"])
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

    function get_direct_deps(proj_dir::AbstractString = get_project_root())
        proj_file = joinpath(proj_dir, "Project.toml")
        proj_toml = TOML.parsefile(proj_file)
        return keys(proj_toml["deps"])
    end



end # module PlutoRevise
