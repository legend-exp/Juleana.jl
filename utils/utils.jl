"""
    checkPermissions(/path/to/directory/or/file, mode)

Given a specific directory or file and mode (options for mode = `r`, `w`, `x` for read/write/execute, respectively), this function checks if the present user has read, write, or execute permissions. Returns Boolean 'true' if current user does have permission, and Boolean false if the user does not have permission. 

The input path can be either a String or a PosixPath. The input mode must be given in double quotes, e.g. "r", "w", "x", though a literal char must be used if calling this function within another function.

# Examples
To check read permissions:
```julia-repl
julia> checkPermissions("/user/home/directory/someFile.txt", "r")  
IS readable.
true
```
To check write permissions:
```julia-repl
julia> checkPermissions("/root", "w")
Is NOT writable.
false
``` 
The returned Boolean can also be assigned:
```julia-repl
julia> x = checkPermissions("/root", "x")
Is NOT executable.
false

julia> (x==false)
true
julia> !(x==false)
false
```
"""
function checkPermissions(path, mode::String) # written like this to allow 'path' to be either a String or PosixPath
    # Inside of this function, 'path' needs to be a string here because we are using ccall. First check if the input 'path' is of type PosixPath
    if (typeof(path)==PosixPath)
       global  inputPath = convert(String, path) # if it is, convert the type to a normal String type.
    elseif (typeof(path)==String)
        # Do nothing, just reassign variable for local type
       global  inputPath = path
    else
        println("Invalid path format given. Please input a String or PosixPath.")
        return false # will handle cases where bad path given 
    end

    # could make all of these more compact with ternary operator, but that is less human-readable
    if mode=="w"
        println("Checking if writable:") # Giving option '2' checks for writability
        (ccall(:access, Cint, (Cstring, Cint), inputPath, 2) == 0;) || (println("Is NOT writable"); return false)
        (ccall(:access, Cint, (Cstring, Cint), inputPath, 2) == 0;) && (println("IS writable"); return true)
    elseif mode=="r"
        println("Checking if readable:") # Giving option '4' checks for readability
        (ccall(:access, Cint, (Cstring, Cint), inputPath, 4) == 0;) || (println("Is NOT readable"); return false)
        (ccall(:access, Cint, (Cstring, Cint), inputPath, 4) == 0;) && (println("IS readable"); return true)
    elseif mode=="x"
        println("Checking if executable:") # Giving option '1' checks for executability
        (ccall(:access, Cint, (Cstring, Cint), inputPath, 1) == 0;) || (println("Is NOT executable"); return false)
        (ccall(:access, Cint, (Cstring, Cint), inputPath, 1) == 0;) && (println("IS executable"); return true)
    end
end



"Checks if a folder exists; if it does, do nothing. If folder does not exist, attempts to create directory."
function checkFolder(folder::PosixPath, create::Bool=false)
    if !exists(folder) #if directory 'folder' does not exist:
        if create #if create is set to true (it is false by default)
            try # checking parent directory to see if it is writable before attempting to create new folder.
                @info "Created folder $folder"
                mkpath(folder)
            catch e # If folder does not exist, but we also do not have write permission (or if parent directory does not exist)
                @info "Could not create folder $folder. Exited script with $e."
                exit(86)
            end
        else
            @info "$folder did not exist, but new directory not created. Exiting script."
            exit(86)
        end
    end
end