local filemanager = {
    preview_winid = -1
}

-- ======================================================================
-- UTILS
-- ======================================================================

local function range(b, e)
    if b > e then b, e = e, b end
    return { b = b, e = e }
end

function string:starts_with(start)
    return self:sub(1, start:len()) == start
end

function string:at(idx)
    return self:sub(idx, idx)
end

local function input(opts, callback)
    vim.ui.input(opts, callback)
    vim.fn.histdel("input", -1)
end

local function split() 
    vim.cmd.split()
    filemanager.open(vim.b.filemanager_dir, vim.b.filemanager_prev_buf)
    filemanager.render()
end

local function vsplit()
    vim.cmd.vsplit()
    filemanager.open(vim.b.filemanager_dir, vim.b.filemanager_prev_buf)
    filemanager.render()
end

-- ======================================================================
-- API
-- ======================================================================

filemanager.keymaps = {
    { modes = "n", lhs = "<C-w>v", rhs = vsplit },
    { modes = "n", lhs = "<C-w><C-v>", rhs = vsplit },
    { modes = "n", lhs = "<C-w>s", rhs = split },
    { modes = "n", lhs = "<C-w><C-s>", rhs = split },

    { -- Close file manager
        modes = "n",
        lhs = "q",
        rhs = function()
            vim.api.nvim_win_set_buf(0, vim.b.filemanager_prev_buf)
        end
    },

    { -- Cd or open file
        modes = "n",
        lhs = "l",
        rhs = function()
            local entry = filemanager.selected_entry()
            if entry == nil then return end

            local path = filemanager.dir_path_with(entry.name)
            if entry.is_dir then
                filemanager.set_dir(path)
                vim.api.nvim_win_set_cursor(0, {1, 0})
            else
                local cwd = vim.fn.getcwd() .. "/"
                if path:starts_with(cwd) then
                    path = path:sub(cwd:len()+1, -1)
                end

                vim.cmd.edit(path)
            end
        end
    },

    { -- Cd back
        modes = "n",
        lhs = "h",
        rhs = function()
            filemanager.set_dir(vim.fs.dirname(vim.b.filemanager_dir))
            vim.api.nvim_win_set_cursor(0, {1, 0})
        end
    },

    { -- Create file
        modes = "n",
        lhs = "a",
        rhs = function()
            input({ prompt = "create: " }, function(input)
                if input == nil or input == "" then return end

                if input:sub(-1) == '/' then
                    vim.fn.mkdir(filemanager.dir_path_with(input), "p")
                else
                    local new_file = io.open(filemanager.dir_path_with(input), "w")
                    new_file:close()
                end

                filemanager.render()
            end)
        end
    },

    { -- Change to edit mode
        modes = "n",
        lhs = "-",
        rhs = function() filemanager.set_edit_mode(0) end
    },

    { -- Delete files
        modes = { "n", "v" },
        lhs = "d",
        rhs = function()
            if #vim.b.filemanager_files == 0 then return end
            input({ prompt = "delete? " }, function(input)
                if input ~= "y" then return end
                for entry in filemanager.selected_entries('v', '.') do
                    vim.fn.system { "rm", "-r", filemanager.dir_path_with(entry.name) }
                end
                filemanager.render()
            end)

            vim.api.nvim_input("<Esc>")
        end
    },

    { -- Mark files; the move mode
        modes = { "n", "v" },
        lhs = "m",
        rhs = function()
            filemanager.mark_files('v', '.', false)
            vim.api.nvim_input("<Esc>")
        end
    },

    { -- Paste files
        modes = "n",
        lhs = "p",
        rhs = function()
            if filemanager.marks == nil then return end

            local command
            if filemanager.marks.copy then
                command = function(src, dst)
                    vim.fn.system { "cp", "-r", src, dst }
                end
            else
                command = function(src, dst)
                    vim.fn.system { "mv", src, dst }
                end
            end

            for _, file_path in pairs(filemanager.marks.file_paths) do
                command(file_path, vim.b.filemanager_dir)
            end
            filemanager.marks = nil

            filemanager.render()
        end
    },

    { -- Set CWD to current tab directory
        modes = "n",
        lhs = "i",
        rhs = function()
            vim.fn.chdir(vim.b.filemanager_dir)
            vim.notify("CWD changed to " .. vim.b.filemanager_dir, vim.log.levels.WARN)
            filemanager.render()
        end
    },

    { -- Set current tab directory to CWD
        modes = "n",
        lhs = ";",
        rhs = function()
            filemanager.set_dir(vim.fn.getcwd())
        end
    },

    { -- Toggle verbose mode
        modes = "n",
        lhs = ".",
        rhs = function()
            filemanager.verbose_mode = not filemanager.verbose_mode
            filemanager.render()
        end
    },

    { -- Rename single file
        modes = "n",
        lhs = "r",
        rhs = function()
            local entry = filemanager.selected_entry()
            if entry == nil then return end

            input({ prompt = "rename: ", default = entry.name }, function(input)
                if input == nil or input == "" then return end
                vim.fn.system { "mv", filemanager.dir_path_with(entry.name),  filemanager.dir_path_with(input) }
                filemanager.render()
            end)
        end
    },

    -- Rerender
    { modes = "n", lhs = "<C-l>", rhs = function() filemanager.render() end },

    { -- Open preview window for the file
        modes = "n",
        lhs = "o",
        rhs = function()
            local entry = filemanager.selected_entry()
            if entry == nil or entry.is_dir then return end
            if not vim.api.nvim_win_is_valid(filemanager.preview_winid) then
                filemanager.preview_winid = vim.api.nvim_open_win(0, false, {
                    split = "right",
                    win = 0
                })
            end

            local path = filemanager.dir_path_with(entry.name)
            vim.api.nvim_win_call(filemanager.preview_winid, function()
                vim.cmd.edit(path)
            end)
        end
    }
}

function filemanager.setup(opts)
    opts.file_manager.keymaps = opts.file_manager.keymaps or {}

    filemanager.ls_opts = opts.file_manager.ls_opts or { "-h", "--group-directories-first" }

    filemanager.augroup = vim.api.nvim_create_augroup("Filemanager", { clear = true })
    filemanager.ns = vim.api.nvim_create_namespace("filemanager")
    vim.api.nvim_set_hl(0, "FilemanagerDir", { default = true, link = "Directory" })
    vim.api.nvim_set_hl(0, "FilemanagerExe", { default = true, link = "PreProc" })
    vim.api.nvim_set_hl(0, "FilemanagerSymLink", { default = true, link = "Question" })

    -- Delete netrw stuff
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1

    -- Auto open filemanager when ':e directory/'
    vim.api.nvim_create_autocmd("BufEnter", {
        group = filemanager.augroup,
        callback = function()
            local new_buf = vim.api.nvim_win_get_buf(0)
            local path = vim.api.nvim_buf_get_name(new_buf)
            local stat = vim.uv.fs_stat(path)
            if stat ~= nil and stat.type == "directory" then
                filemanager.open(path)
                filemanager.render()
                vim.api.nvim_buf_delete(new_buf, { force = true })
            end
        end
    })

    -- Open filemanager keymap
    vim.keymap.set("n", opts.file_manager.open or "<leader>p", function()
        local curr_buf_name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
        local curr_buf_dir = vim.fs.dirname(curr_buf_name)
        filemanager.open(curr_buf_dir)
        filemanager.render()
    end)

    if not opts.shell_command.disabled then
        local sc = require("simple.shell_command")
        table.insert(filemanager.keymaps, {
            modes = "n",
            lhs = opts.shell_command.keymaps.input,
            rhs = function() sc.input({ cwd = vim.b.filemanager_dir }) end
        })
        table.insert(filemanager.keymaps, {
            modes = "n",
            lhs = opts.shell_command.keymaps.run_last,
            rhs = function() sc.run_last_or_input(vim.b.filemanager_dir) end
        })
        table.insert(filemanager.keymaps, {
            modes = "v",
            lhs = opts.shell_command.keymaps.input,
            rhs = function()
                local s = ""
                for entry in filemanager.selected_entries('v', '.') do
                    s = s .. " " .. entry.name
                end
                vim.cmd.normal("")
                sc.input({ cwd = vim.b.filemanager_dir, cmd_suffix = s })
            end
        })
        if opts.telescope_integration then
            if not opts.shell_command.disabled then
                table.insert(filemanager.keymaps, {
                    modes = "n",
                    lhs = opts.shell_command.keymaps.search_history or "<leader>h",
                    rhs = function() sc.search_history(vim.b.filemanager_dir) end
                })
            end
        end
    end

    if opts.telescope_integration then
        local ts = require("telescope.builtin")
        table.insert(filemanager.keymaps, {
            modes = "n",
            lhs = opts.file_manager.keymaps.telescope_find_files or "<leader>f",
            rhs = function() ts.find_files({ cwd = vim.b.filemanager_dir }) end
        })
        table.insert(filemanager.keymaps, {
            modes = "n",
            lhs = opts.file_manager.keymaps.telescope_live_grep or "<leader>/",
            rhs = function() ts.live_grep({ cwd = vim.b.filemanager_dir }) end
        })
    end
end

function filemanager.set_explore_mode(buf)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("filetype", "filemanager", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.opt_local.cursorline = true

    for _, keymap in ipairs(filemanager.keymaps) do
        vim.keymap.set(keymap.modes, keymap.lhs, keymap.rhs, { buffer = buf })
    end

    -- Mark files; the copy mode
    vim.api.nvim_create_autocmd("TextYankPost", {
        buffer = buf,
        callback = function()
            if vim.api.nvim_get_option_value("filetype", { buf = 0 }) == "filemanager" then
                local event = vim.api.nvim_get_vvar("event")
                if event.operator ~= 'y' then return end
                filemanager.mark_files("'[", "']", true)
            end
        end
    })
end

function filemanager.set_edit_mode(buf)
    local cmd = vim.fn.extend({ "ls", "-1", vim.b[buf].filemanager_dir }, filemanager.ls_opts)
    if filemanager.verbose_mode then table.insert(cmd, "-A") end
    local res = vim.system(cmd, { text = true }):wait()
    if res.code ~= 0 then
        vim.notify(res.stderr, vim.log.levels.ERROR)
        return
    end

    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_set_option_value("filetype", "text", { buf = buf })
    vim.opt_local.cursorline = false

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.split(res.stdout, '\n'))

    for _, keymap in ipairs(filemanager.keymaps) do
        vim.keymap.del(keymap.modes, keymap.lhs, { buffer = buf })
    end

    vim.keymap.set("n", "-", function()
        input({ prompt = "apply changes? " }, function(input)
            if input == "y" then
                local files_after_editing = vim.api.nvim_buf_get_lines(0, 0, -1, true)
                if #files_after_editing ~= #vim.b.filemanager_files then
                    vim.notify("Different number of files", vim.log.levels.ERROR)
                    return
                end

                for i = 1, #files_after_editing do
                    if vim.b.filemanager_files[i] ~= files_after_editing[i] then
                        has_renamings = true
                        local old_path = vim.fs.joinpath(vim.b[0].filemanager_dir, vim.b.filemanager_files[i].name)
                        local new_path = vim.fs.joinpath(vim.b[0].filemanager_dir, files_after_editing[i])
                        vim.fn.system { "mv", old_path, new_path }
                    end
                end

                filemanager.set_explore_mode(0)
                filemanager.render()
            elseif input == "n" then
                filemanager.set_explore_mode(0)
                filemanager.render()
            end
        end)
    end)
end

function filemanager.open(path, prev_buf)
    local norm_path = vim.fs.normalize(vim.fs.abspath(path))
    if vim.uv.fs_stat(norm_path) == nil then
        print("Path does not exist")
        return
    end

    filemanager.verbose_mode = false
    local filemanager_prev_buf = prev_buf or vim.api.nvim_get_current_buf()

    local new_filemanager_buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_win_set_buf(0, new_filemanager_buf)
    filemanager.set_explore_mode(new_filemanager_buf)

    vim.b.filemanager_dir = norm_path
    vim.b.filemanager_prev_buf = filemanager_prev_buf
end

function filemanager.set_dir(path)
    vim.b.filemanager_dir = path
    filemanager.render()
end

function filemanager.render()
    local cmd = vim.fn.extend({ "ls", "-l", "--dired", vim.b.filemanager_dir }, filemanager.ls_opts)
    if filemanager.verbose_mode then
        table.insert(cmd, "-A")
    end

    local res = vim.system(cmd, { text = true }):wait()
    if res.code ~= 0 then
        vim.notify(res.stderr, vim.log.levels.ERROR)
        return
    end

    local lines = vim.fn.split(res.stdout, '\n')
    local dired = vim.fn.split(lines[#lines-1]:sub(11), ' ')

    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.slice(lines, 0, -2))
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    local line = 2
    local line_begin = vim.fn.strlen(lines[1]) + 1
    local files = {}
    for i=1, #dired, 2 do
        local name_begin, name_end  = dired[i]+1, dired[i+1]
        local name = res.stdout:sub(name_begin, name_end)
        local mode = lines[line]:sub(3, 12)

        local hl = "NormalNC"
        if mode:at(1) == 'd' then
            table.insert(files, { name = name, is_dir = true })
            hl = "FilemanagerDir"
        else
            table.insert(files, { name = name, is_dir = false })
            if mode:at(1) == 'l' then
                hl = "FilemanagerSymLink"
            elseif mode:at(4) == 'x' then
                hl = "FilemanagerExe"
            end
        end

        local name_pos_begin = { line - 1, name_begin - line_begin - 1 }
        local name_pos_end = { line - 1, name_end - line_begin }
        vim.hl.range(buf, filemanager.ns, hl, name_pos_begin, name_pos_end)

        line_begin = line_begin + vim.fn.strlen(lines[line]) + 1
        line = line + 1
    end

    vim.b.filemanager_files = files
end

function filemanager.dir_path_with(path)
    return vim.fs.joinpath(vim.b.filemanager_dir, path)
end

function filemanager.mark_files(reg1, reg2, as_copy)
    if #vim.b.filemanager_files == 0 then return end
    filemanager.marks = { copy = as_copy, file_paths = {} }
    for entry in filemanager.selected_entries(reg1, reg2) do
        table.insert(filemanager.marks.file_paths, filemanager.dir_path_with(entry.name))
    end
end

function filemanager.selected_entry()
    local row = vim.fn.getpos(".")[2]
    if row == 1 then return nil end
    return vim.b.filemanager_files[row - 1]
end

function filemanager.selected_entries(reg1, reg2)
    local range = range(vim.fn.getpos(reg1)[2], vim.fn.getpos(reg2)[2])
    if range.b == 1 then
        range.e = range.e - 1
    else
        range.b = range.b - 1
        range.e = range.e - 1
    end

    local idx = range.b - 1
    return function()
        idx = idx + 1
        if idx <= range.e then
            return vim.b.filemanager_files[idx]
        end
    end
end

return filemanager
