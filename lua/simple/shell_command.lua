local sc = {
    output_bufnr = -1,
    output_winid = -1,
}

local pickers
local finders
local conf
local actions
local action_state

function sc.setup(opts)
    opts.shell_command.keymaps = opts.shell_command.keymaps or {}

    sc.gen_cmd_to_run_cmd_interpreter = opts.shell_command.gen_cmd_to_run_cmd_interpreter or function(user_input)
        return { "bash", "-c", user_input }
    end

    opts.shell_command.keymaps.input = opts.shell_command.keymaps.input or "<leader>;"
    opts.shell_command.keymaps.run_last = opts.shell_command.keymaps.run_last or "<leader>l"
    opts.shell_command.keymaps.scroll_output_up = opts.shell_command.keymaps.scroll_output_up or "<C-k>"
    opts.shell_command.keymaps.scroll_output_down = opts.shell_command.keymaps.scroll_output_down or "<C-j>"

    vim.keymap.set("n", opts.shell_command.keymaps.input, sc.input)
    vim.keymap.set("n", opts.shell_command.keymaps.run_last, sc.run_last_or_input)
    vim.keymap.set("n", opts.shell_command.keymaps.scroll_output_up, sc.scroll_output_up)
    vim.keymap.set("n", opts.shell_command.keymaps.scroll_output_down, sc.scroll_output_down)

    if opts.telescope_integration then
        sc.telescope_opts = opts.shell_command.telescope_opts
        opts.shell_command.keymaps.search_history = opts.shell_command.keymaps.search_history or "<leader>h"
        vim.keymap.set("n", opts.shell_command.keymaps.search_history, sc.search_history)
        pickers = require("telescope.pickers")
        finders = require("telescope.finders")
        conf = require("telescope.config").values
        actions = require("telescope.actions")
        action_state = require("telescope.actions.state")
    end

    sc.history_len = opts.shell_command.history_len or 100
end

function sc.open_output_win()
    local tabpage_wins = vim.api.nvim_tabpage_list_wins(0)
    if vim.fn.index(tabpage_wins, sc.output_winid) ~= -1 then
        vim.api.nvim_win_set_buf(sc.output_winid, sc.output_bufnr)
    else
        if vim.api.nvim_win_is_valid(sc.output_winid) then
            vim.api.nvim_win_close(sc.output_winid, false)
        end

        sc.output_winid = vim.api.nvim_open_win(sc.output_bufnr, false, {
            split = 'below',
            win = 0,
        })
    end
end

function sc.run(user_input, cwd)
    if not vim.api.nvim_buf_is_loaded(sc.output_bufnr) then
        sc.output_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(sc.output_bufnr, "[Shell Command]")
    end

    sc.open_output_win()

    if sc.chan_id ~= nil then
        vim.notify("Another process is still running", vim.log.levels.ERROR)
        return
    end

    if sc.output_chan_id ~= nil then vim.fn.chanclose(sc.output_chan_id) end
    sc.output_chan_id = vim.api.nvim_open_term(sc.output_bufnr, {
        on_input = function(_, _, _, data)
            if data == "" and sc.chan_id then
                vim.fn.jobstop(sc.chan_id)
            end
        end
    })

    sc.chan_id = vim.fn.jobstart(sc.gen_cmd_to_run_cmd_interpreter(user_input), {
        cwd = cwd,
        pty = true,
        on_stdout = function(_, data)
            assert(sc.output_chan_id)
            vim.fn.chansend(sc.output_chan_id, data)
        end,
        on_stderr = function(_, data)
            assert(sc.output_chan_id)
            vim.fn.chansend(sc.output_chan_id, data)
        end,
        on_exit = function(_, exit_code)
            assert(sc.output_chan_id)
            vim.api.nvim_chan_send(sc.output_chan_id, "\n[Process exited "..exit_code.."]")
            sc.chan_id = nil
        end
    })

    vim.api.nvim_buf_call(sc.output_bufnr, function()
        vim.cmd.normal("G")
    end)
end

-- Completion function
vim.cmd([[
function! CompileInputComplete(ArgLead, CmdLine, CursorPos)
    let HasNoSpaces = a:CmdLine =~ '^\S\+$'
    let Results = getcompletion('!' . a:CmdLine, 'cmdline')
    let TransformedResults = map(Results, 'HasNoSpaces ? v:val : a:CmdLine[:strridx(a:CmdLine, " ") - 1] . " " . v:val')
    return TransformedResults
endfunction
]])

function sc.run_last_or_input(cwd)
    if sc.last_cmd == nil then
        sc.input({ cwd = cwd })
    else
        sc.run(sc.last_cmd, cwd)
    end
end

function sc.history()
    local history = vim.api.nvim_cmd({ cmd = "history", args = {"input"} }, { output = true })
    history = vim.fn.split(history, '\n')

    local last_entry = history[#history];
    assert(last_entry:sub(1, 1) == '>')
    last_entry = vim.fn.trim(last_entry:sub(2), " ", 1)
    last_entry = last_entry:sub(vim.fn.stridx(last_entry, " ") + 1)
    last_entry = last_entry:sub(4)

    local prefix_end = vim.fn.strlen(history[#history]) - vim.fn.strlen(last_entry)
    for i, entry in ipairs(history) do
        history[i] = entry:sub(prefix_end)
    end

    return vim.fn.slice(vim.fn.reverse(history), 0, sc.history_len)
end

function sc.input(opts)
    opts = opts or {}
    vim.ui.input({ prompt = "sh: ", default = opts.default or "", completion=("customlist,%s"):format("CompileInputComplete") }, function(new_cmd)
        if new_cmd == nil or new_cmd == "" then return end
        if opts.cmd_suffix then
            new_cmd = new_cmd .. opts.cmd_suffix
        end

        sc.last_cmd = new_cmd
        sc.run(new_cmd, opts.cwd)
    end)
end

function sc.scroll_output_up()
    if vim.api.nvim_buf_is_loaded(sc.output_bufnr) then
        sc.open_output_win()
        vim.api.nvim_win_call(sc.output_winid, function()
            vim.cmd("exe \"normal! \\<C-u>\"")
        end)
    end
end

function sc.scroll_output_down()
    if vim.api.nvim_buf_is_loaded(sc.output_bufnr) then
        sc.open_output_win()
        vim.api.nvim_win_call(sc.output_winid, function()
            vim.cmd("exe \"normal! \\<C-d>\"")
        end)
    end
end

function sc.search_history(cwd)
    local opts = sc.telescope_opts or {}
    pickers.new(opts, {
        prompt_title = "Shell Command History",
        finder = finders.new_table { results = sc.history() },
        sorter = conf.generic_sorter(opts),
        attach_mappings = function(promp_bufnr, map)
            actions.select_default:replace(function()
                actions.close(promp_bufnr)
                local selection = action_state.get_selected_entry()[1]
                sc.input({ default = selection, cwd = cwd })
            end)

            return true
        end
    }):find()
end

return sc
