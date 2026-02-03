# PlutoRevise.jl

> [!WARNING]
> This package is still at a very early stage of development and is expected to evolve significantly in the near future.

This package can be considered the successor of `PlutoDevMacros.jl` for the purpose of simplifying the load of a local package within a notebook without interfering with the Pluto integrated package manager.
It drops the functionality of PlutoDevMacros for creating packages with Pluto notebook as package files so for that PlutoDevMacros is still the package to use.

This package now completely relies on `Revise.jl` to streamline the revision of package code, allowing the following benefits:
- It allows to use the precompiled cached code the first time the package is loaded in the notebook
- It supports revision of package code without manual rerun (directly supported by Pluto), which can be useful for rerunning just specific cells after code change without having to reload all cells that depends on the cell containing the `@fromparent` macro
  
Additionally, this package now changes the execution model of package loading from within the `@fromparent` macro by exploiting `AbstractPlutoDingetjes.with_js_link` to parse package code at runtime before reloading the cell instead of doing so during macro expansion time.
This is mostly done in order to allow displaying of progress meter during the potentially long re-execution of code
> [!NOTE]
> The code loading at runtime is already implemented, but there is still no implementation of a progress bar to show the code loading status during cell execution.