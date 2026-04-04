return {
    setup = function(opts)
        opts = opts or {}
        opts.telescope_integration = package.loaded["telescope"]

        opts.shell_command = opts.shell_command or {}
        if not opts.shell_command.disabled then
            require("simple.shell_command").setup(opts)
        end

        opts.file_manager = opts.file_manager or {}
        if not opts.file_manager.disabled then
            require("simple.file_manager").setup(opts)
        end
    end
}
