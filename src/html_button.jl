function inner_reload_function(input)
    @info "Rerunning Cell"
    cell_dependencies = input["deps"]
    full_reload = input["full_reload"]
    if full_reload
        cell_id = cell_dependencies["cell_id"] |> Base.UUID
        m = CELL_TO_PACKAGE[cell_id]
        @info "Forcing revision of module $(nameof(m))"
        Revise.revise(m)
    end
    return true
end

function invalidate(args...)
    @info "invalidating"
    true
end

function html_reload_button(cell_id; name)
    id = string(cell_id)
    text_content = "Reload $name"
    out = @htl("""
    <reload-container class='$name'>
    <style>
        reload-container:before {
            content: "$text_content";
        }
        reload-container {
            height: 20px;
            position: fixed;
            top: 40px;
            right: 10px;
            margin-top: 5px;
            padding-right: 5px;
            z-index: 200;
            background: var(--overlay-button-bg);
            padding: 5px 8px;
            border: 3px solid var(--overlay-button-border);
            border-radius: 12px;
            height: 35px;
            font-family: "Segoe UI Emoji", "Roboto Mono", monospace;
            font-size: 0.75rem;
            visibility: visible;
        }

        reload-container.PlutoRevise {
            right: auto;
            left: 10px;
        }

        reload-container.errored {
            border-color: var(--error-cell-color);
        }
        reload-container:hover {
            font-weight: 800;
            cursor: pointer;
        }
        body.disable_ui reload-container {
            display: none;
        }
    </style>
    <script>
        const cell = currentScript.closest('pluto-cell');
        const actions = cell._internal_pluto_actions
        const julia_function = $(with_js_link(inner_reload_function))

        const button = currentScript.parentElement;
        let clickTimer = null;

        const runReload = async (fullReload) => {
            const should_reload = await julia_function({ deps: actions.get_notebook().cell_dependencies[$id], full_reload: fullReload});
            if (should_reload) {
                console.log('reloading cell $id for package $name. Full related: ' + fullReload);
                actions.set_and_run_multiple([cell.id]);
            }
        };

        button.addEventListener('click', () => {
            if (clickTimer) {
                clearTimeout(clickTimer);
                clickTimer = null;
                runReload(true);
            } else {
                clickTimer = setTimeout(() => {
                    clickTimer = null;
                    runReload(false);
                }, 200);
            }
        });
    </script>
    </reload-container>
    """)
end

macro testreload()
    r = rand()
    @htl("""
    <div>
        <div>$r</div>
        <div>$(rand())</div>
        <script>
            const cell = currentScript.closest('pluto-cell');
            const actions = cell._internal_pluto_actions

            const julia_function = $(with_js_link(inner_reload_function, invalidate))

            const parent = currentScript.parentElement;
            parent.addEventListener('click', async (event) => {
                console.log('clicked testreload')
                actions.set_and_run_multiple([cell.id]);
            });

        </script>
    </div>
    """)
end