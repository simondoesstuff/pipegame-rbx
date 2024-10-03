local Public = {}

function Public.projByNormal(vector: Vector3, normal: Vector3)
    -- Projects a vector into the plane of the normal.
    normal = normal.Unit
    return vector - normal:Dot(vector) * normal
end

return Public