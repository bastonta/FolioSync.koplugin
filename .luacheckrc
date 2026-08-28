std = "lua51"
globals = {
    "G_reader_settings",
    "Dispatcher",
    "gettext",
}
self = false
max_line_length = false
exclude_files = {
    "build",
    "koreader",
}

files["spec/**"] = {
    std = "+busted",
    unused_args = false,
    unused_vararg = false,
    globals = {
        "G_reader_settings",
        "Dispatcher",
        "gettext",
    },
}

