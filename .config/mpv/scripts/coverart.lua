--[[
    This script automatically loads external coverart files into mpv as additional video tracks.

    By default the script searches the folder that the current file is in, but it can also search in
    the parent folder and the current playlist. By default the script will automatically search the playlist
    if it can't access the directory of the current file (usually when playing a network file).

    If --audio-display=no is set then this script will not load any coverart. If --vid=no is set then this
    script will load external coverart, but will not select them my default. Any other value for vid will only
    properly select internal coverart, though you might get lucky and have it select the right track by chance.

    Look at the below table for the full list of options, see the mpv manual for how to set options (the osc chapter has good examples)
    the option prefix is 'coverart-'
]]--

--list of options
local o = {
    --list of names of valid cover art, must be separated by semicolons with no spaces
    --the script is not case specific
    --any file with valid names and valid image extensions are loaded
    --if set to blank then image files with any name will be loaded
    names = "cover;folder;album;front",

    --valid image extensions, same syntax as the names option
    --leaving it blank will load files of any type (with the matching filename)
    --leaving both lists blank is not a good idea
    imageExts = 'jpg;jpeg;png;bmp;gif',

    --will pick any image if it can't find one with our preferred names
    any_image_fallback = false,

    --by default it only loads coverart if it detects the file is an audio file
    --an audio file is one where mpv reports the first stream as being audio or albumart
    always_scan_coverart = false,

    --if false stops looking for coverart after finding a single valid file
    --and doesn't look at all if the file already has internal coverart
    load_extra_files = true,

    --file path of a placeholder image to use if no cover art is found
    --will only be used if force-window is enabled
    --leaving it blank will be the same as disabling it
    placeholder = "",

    --searches for valid coverart in the filesystem
    load_from_filesystem = true,

    --search for valid coverart in the current playlist
    --this may seem pointless, but it's useful for streaming from
    --network file servers which mpv can't usually scan
    --this entry causes the script to always search the playlist,
    --for the default behaviour described in the README see below
    load_from_playlist = false,

    --attempts to load from playlist automatically if it can't find anything on the file system
    --this overrides the load_from_playlist entry above
    auto_load_from_playlist = true,

    --If this is enabled then only valid coverart in the playlist that is
    --also in the same directory as the currently playing file will be loaded.
    --If disabled, then any valid coverart in the playlist will be loaded.
    enforce_playlist_directory = true,

    --scans the parent directory for coverart as well, this
    --currently doesn't do anything when loading from a playlist
    check_parent = false,

    --skip coverart files if they are in the playlist
    skip_coverart = false,

    --decode URL percent encoding
    decode_urls = false,

    --protocols to do percent decoding for
    --use semicolons to split protocols
    decode_protocols = "ftp;sftp"
}
local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local opt = require 'mp.options'
opt.read_options(o, 'coverart')

local names = {}
local imageExts = {}
local decodeProtocols = {}
local prev = {
    directory = "",
    coverart = {}
}

o.placeholder = mp.command_native({"expand-path", o.placeholder})

function hasValue(tab, value)
    for i, val in ipairs(tab) do
        if val == value then
            return true
        end
    end
    return false
end

--splits the string into a table on the semicolons
function create_table(input)
    local t={}
    for str in string.gmatch(input, "([^;]+)") do
            t[str] = true
    end
    return t
end

--processes the option strings to ensure they work with the script
function processStrings()
    --sets everything to lowercase to avoid confusion
    o.names = string.lower(o.names)
    o.imageExts = string.lower(o.imageExts)

    --splits the strings into tables
    names = create_table(o.names)
    imageExts = create_table(o.imageExts)
    decodeProtocols = create_table(o.decode_protocols)
end

processStrings()

--a music file is one where mpv returns an audio stream or coverart as the first track
function is_audio_file()
    if mp.get_property('track-list/0/type') == "audio" then
        return true
    elseif mp.get_property('track-list/0/albumart') == "yes" then
        return true
    end
    return false
end

--decodes a URL address
--this piece of code was taken from: https://stackoverflow.com/questions/20405985/lua-decodeuri-luvit/20406960#20406960
local decodeURI
do
    local char, gsub, tonumber = string.char, string.gsub, tonumber
    local function _(hex) return char(tonumber(hex, 16)) end

    function decodeURI(s)
        msg.debug('decoding string: ' .. s)
        s = gsub(s, '%%(%x%x)', _)
        msg.debug('returning string: ' .. s)
        return s
    end
end

--checks if the path uses a protocol that requires encoding
function needsDecoding(path)
    local index = path:find(":")
    local protocol = path:sub(1, index-1)
    return decodeProtocols[protocol]
end

--loads a placeholder image as cover art for the file
function loadPlaceholder()
    if o.placeholder == "" then return end
    if not ((mp.get_property('vid') == "no" and mp.get_property('options/vid', "") == "auto") and mp.get_property_bool('force-window')) then return end

    msg.verbose('file does not have video track, loading placeholder')
    loadCover(o.placeholder)
end

--splits filename into a name and extension
function splitFileName(file)
    file = string.lower(file)

    --finds the file extension
    local index = file:find([[.[^.]*$]])
    local fileext = file:sub(index + 1)

    --find filename
    local filename = file:sub(0, index - 1)

    return filename, fileext
end

--checks if the given file matches the cover art requirements
function isValidCoverart(file)
    msg.verbose('testing if ' .. file .. ' is valid coverart')
    local filename, fileext = splitFileName(file)

    if o.imageExts ~= "" and not imageExts[fileext] then
        msg.debug('"' .. fileext .. '" not in whitelist')
        return false
    else
        msg.debug('"' .. fileext .. '" valid, checking for valid name...')
    end
    return true
end

function isValidCoverart_full(file)
    msg.verbose('testing if ' .. file .. ' is valid coverart')
    local filename, fileext = splitFileName(file)

    if o.imageExts ~= "" and not imageExts[fileext] then
        msg.debug('"' .. fileext .. '" not in whitelist')
        return false
    else
        msg.debug('"' .. fileext .. '" valid, checking for valid name...')
    end
    if o.names == "" or names[filename] then
        msg.debug('filename valid')
        return true
    end
    msg.debug('filename invalid')
    return false
end

--loads the coverart
function loadCover(path)
    if o.decode_urls and needsDecoding(path) then
        msg.debug('decoding URL')
        path = decodeURI(path)
    end
    table.insert(prev.coverart, path)
    addVideo(path)
end

--adds the new file to the playing list
--if there is no video track currently selected then it autoloads track #1
function addVideo(path)
    if mp.get_property_number('vid', 0) == 0 and mp.get_property('options/vid') == "auto" then
        mp.commandv('video-add', path)
    else
        mp.commandv('video-add', path, "auto")
    end
end

--searches and adds valid coverart from the specified directory
function addFromDirectory(directory)
    local files = utils.readdir(directory, "files")
    if files == nil then
        msg.verbose('no files could be loaded from ' .. directory)
        return false
    end
    msg.verbose('scanning files in ' .. directory)

    --loops through the all the files in the directory to find if any are valid cover art
    local fallbacks = {}
    local success = 0
    for i, file in ipairs(files) do
        --if the name matches one in the whitelist then load it
        if isValidCoverart(file) then
            local filename, fileext = splitFileName(file)
            if o.names == "" or names[filename] then
                msg.debug('filename valid')
                msg.verbose(file .. ' found in whitelist - adding as extra video track...')
                success = 1
                loadCover(utils.join_path(directory, file))
                if not o.load_extra_files then return 1 end
            elseif o.any_image_fallback then
                msg.debug('filename invalid - adding to fallback list...')
                table.insert(fallbacks, file)
            else
                msg.debug('filename invalid')
            end
        end
    end
    if o.any_image_fallback and success == 0 then
        for i, file in ipairs(fallbacks) do
            success = 1
            loadCover(utils.join_path(directory, file))
            if not o.load_extra_files then return 1 end
        end
    end
    return success
end

function checkForCoverart()
    --aborts the script if audio-display is disabled
    if mp.get_property('audio-display', "no") == "no" then
        msg.verbose('audio-display is disabled, aborting script')
        return
    end

    --does not look for cover art if the file is not an audio file
    if not o.always_scan_coverart and not is_audio_file() then
        msg.verbose('file is not an audio file, aborting coverart search')
        loadPlaceholder()
        return
    end

    --if the file has video tracks then we cancel the cover lookup
    if (not o.load_extra_files) and (mp.get_property_number('vid', 0) ~= 0) then
        return
    end

    --if auto is not selected, then we need to scan the tracklist to
    --see if there is existing coverart
    if (not o.load_extra_files) and mp.get_property('options/vid') ~= "auto" then
        msg.verbose('scanning track-list for coverart')
        local tracks = mp.get_property_native('track-list', {})
        for i,v in ipairs(tracks) do
            if v.type == "video" then
                msg.verbose('video stream found, aborting coverart search')
                return
            end
        end
    end

    --finds the local directory of the file
    local workingDirectory = mp.get_property('working-directory')
    msg.verbose('working-directory: ' .. workingDirectory)
    local filepath = mp.get_property('path')
    msg.verbose('filepath: ' .. filepath)
    local exact_path = utils.join_path(workingDirectory, filepath)
    msg.verbose('full path: ' .. exact_path)

    --splits the directory and filename apart
    local directory = utils.split_path(exact_path)
    msg.verbose('directory: ' .. directory)

    --checks if the directory is the same as the previous file, and if so just reloads
    --the same coverart again
    if directory == prev.directory then
        msg.verbose('Same directory as previous file, skipping coverart check')
        for _,path in ipairs(prev.coverart) do
            addVideo(path)
        end
        return
    else
        prev.directory = directory
        prev.coverart = {}
    end

    local succeeded = false
    if o.load_from_filesystem then
        --loads the files from the directory
        succeeded = addFromDirectory(directory)
        if not o.load_extra_files and succeeded > 0 then return end

        if o.check_parent and succeeded then
            succeeded = addFromDirectory(directory .. "/../")
            if not o.load_extra_files and succeeded > 0 then return end
        end
    end
    if ((not succeeded) and o.auto_load_from_playlist) or o.load_from_playlist then
        --loads files from playlist
        msg.verbose('searching for coverart in current playlist')
        local pls = mp.get_property_native('playlist')
        local fallbacks = {}

        for i,v in ipairs(pls)do
            local dir, name = utils.split_path(v.filename)
            if (not o.enforce_playlist_directory) or utils.join_path(workingDirectory, dir) == directory then
                if isValidCoverart(name) then
                    local filename, fileext = splitFileName(name)
                    if o.names == "" or names[filename] then
                        msg.debug('filename valid')
                        msg.verbose('found cover in playlist')
                        loadCover(v.filename)
                        if not o.load_extra_files then return end
                        succeeded = 1
                    elseif o.any_image_fallback then
                        msg.debug('filename invalid - adding to fallback list...')
                        table.insert(fallbacks, v.filename)
                    else
                        msg.debug('filename invalid')
                    end
                end
            end
        end
        if o.any_image_fallback and succeeded ~= 1 then
            for i, file in ipairs(fallbacks) do
                succeeded = 1
                loadCover(file)
                if not o.load_extra_files then return 1 end
            end
        end
    end

    --loads a placeholder image if no covers were found and a window is forced
    if succeeded ~= 1 then loadPlaceholder() end
end

--runs automatically whenever a file is loaded
mp.register_event('file-loaded', checkForCoverart)

--to force an update during runtime
mp.register_script_message('load-coverart', checkForCoverart)

--resets the cache of coverart for 
mp.observe_property('playlist-count', 'number', function()
    prev.directory = ""
end)

--skips coverart in the playlist
if o.skip_coverart then
    mp.add_hook('on_load', 30, function()
        if (isValidCoverart_full(mp.get_property('filename', '')) or (isValidCoverart(mp.get_property('filename', '')) and hasValue(prev.coverart, mp.get_property('filename', '')))) and mp.get_property_number('playlist-count') > 1 then
            msg.info('skipping coverart in playlist')
            mp.command('playlist-next')
        end
    end)
end