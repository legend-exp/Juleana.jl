out_t = TypedTables.Table(test=Int[])

function testTable(tab::TypedTables.Table)
    push!(tab.test, 1)
end

testTable(out_t)
