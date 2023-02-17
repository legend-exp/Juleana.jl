function checkFolder(folder::PosixPath, create::Bool=false)
    if !exists(folder)
        if create
            println("Create folder $folder")
            mkpath(folder)
        else
            println("$folder does not exist, exit script")
            exit(86)
        end
    end
end


