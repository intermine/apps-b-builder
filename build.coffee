#!/usr/bin/env coffee
Builder = require 'component-builder'

{ _ }    = require 'lodash'
async    = require 'async'
{ exec } = require 'child_process'
path     = require 'path'
os       = require 'os'
fs       = require 'fs'
log      = require 'node-logging'

# Determine quotes for escaping paths.
quotes = if os.type() is "Windows_NT" then "\"" else "'"

module.exports = (io, cb) ->
    # Resolve paths.
    return cb 'Incorrect number of params' if io.length isnt 2
    io = _.map io, (rel) -> path.resolve process.cwd(), rel

    # Check the dirs exist.
    async.each io, (loc, cb) ->
        fs.exists loc, (ya) ->
            return cb "#{loc} does not exist" unless ya
            fs.stat loc, (err, stats) ->
                return cb err if err
                return cb "#{loc} is not a directory" unless stats.isDirectory()
                cb null
    
    , (err) ->
        return cb err if err

        # Build our handlers based on types.
        dir = __dirname

        fs.readdir dir + '/types', (err, files) ->
            return cb err if err

            [ input, output ] = io

            # Load them handlers from our /types.
            handlers = {}
            _.each files, (file) ->
                [ hook, extensions, handler ] = exported = require dir + '/types/' + file
                handlers[hook] ?= {}

                switch
                    # An Array.
                    when _.isArray(extensions)
                        ( handlers[hook][ext] = wrapper.apply(@, exported) for ext in extensions )

                    # A String.
                    when _.isString(extensions)
                        handlers[hook][extensions] = wrapper.apply @, exported

            # Capture Builder errors.
            class Proxy extends Builder

                json: ->
                    try
                        Builder::json.call @, arguments
                    catch e
                        return cb e.message

            # Init a new builder.
            builder = new Proxy input

            # Use our custom hooks.
            builder.use hooker handlers

            # Read the `component.json` file.
            async.waterfall [ (cb) ->
                fs.readFile input + '/component.json', 'utf-8', (err, file) ->
                    try
                        cb null, JSON.parse(file)
                    catch e
                        cb e

            # Install deps, filter config.?
            (json, cb) ->
                # # Explicitely pass the config skipping build files if present.
                # for key in [ 'scripts', 'styles' ]
                #     json[key] ?= []
                #     json[key] = _.filter json[key], (file) ->
                #         not new RegExp('build\.[js|css]').test file

                # Override the default load.
                builder.config = json

                # Why you need deps? Go native... :)
                return cb(null) unless json.dependencies

                # Run them installs in series.
                async.eachSeries ( "#{n}@#{v}" for n, v of json.dependencies ), (dep, cb) ->
                    exec "#{quotes}#{dir}/node_modules/.bin/component-install#{quotes} #{dep} --out #{quotes}#{input}/components#{quotes}", (err, stdout, stderr) ->
                        return cb err if err
                        return cb stderr if stderr
                        cb null
                , cb

            # Clear build files (avoid building the build).
            , (cb) ->
                async.each [ 'js', 'css' ], (where, cb) ->
                    fs.truncate "#{output}/build.#{where}", 0, cb
                , cb

            # Build it...
            , (cb) ->
                # TODO: deal with assets.
                builder.build (err, res) ->
                    cb err, res

            # ... and they will come!
            , (res, cb) ->
                write = (where, what, cb) ->
                    fs.writeFile "#{output}/build.#{where}", what, cb

                async.parallel [
                    _.partial write, 'js', res.require + res.js
                    _.partial write, 'css', res.css
                ], cb

            # Done.
            ], cb

# What are the targets we are coverting to?
convertTo =
    'scripts': '.js'
    'styles':  '.css'

# Load a file, handle it, switch it, go home.
wrapper = (hook, extension, handler) ->
    (pkg, file, cb) ->
        p = pkg.path file
        # Read file.
        fs.readFile p, 'utf8', (err, src) ->
            return cb err if err
            # Process in handler.
            handler src, (err, out) ->
                if err
                    log.bad file
                    return cb err.message

                # Switcheroo.
                name = path.basename(file, extension) + convertTo[hook]
                dir = '' if (dir = path.dirname(file) + '/') is './'
                pkg.addFile hook, dir + name, out
                pkg.removeFile hook, file
                # We done.
                cb null

# Register all hooks.
hooker = (handlers) ->
    (builder) ->
        for hook, obj of handlers then do (hook, obj) ->
            builder.hook "before #{hook}", (pkg, cb) ->
                # Empty?
                return cb(null) unless (files = pkg.config[hook] or []).length

                # Map to handlers.
                files = _.map files, (file) ->
                    (cb) ->
                        cb = _.wrap cb, (fn, err) ->
                            fn err

                        # Can build.
                        return fn(pkg, file, cb) if fn = obj[path.extname(file)]
                        
                        # Normal files.
                        cb null

                # And exec in series (why!?).
                async.series files, (err) ->
                    cb err