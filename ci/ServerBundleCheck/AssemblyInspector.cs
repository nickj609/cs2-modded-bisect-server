using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;

namespace ServerBundleCheck;

// What the checker needs to know about one DLL, read from metadata only (nothing is loaded or run).
public sealed class AssemblyInfo
{
    public required string Path { get; init; }
    public required string Name { get; init; }
    public Version Version { get; init; } = new();
    public string? InformationalVersion { get; init; }

    // ".NETCoreApp,Version=v8.0" -> 8
    public string? TargetFramework { get; init; }
    public int? TargetMajor { get; init; }
    public List<(string Name, Version Version)> References { get; init; } = new();

    // Set when the DLL contains a CounterStrikeSharp plugin (a class with a ModuleName property).
    public string? ModuleName { get; init; }
    public string? ModuleVersion { get; init; }
    public int? MinimumApiVersion { get; init; }
    public bool IsPlugin => ModuleName != null || PluginClass != null;
    public string? PluginClass { get; init; }
}

public static class AssemblyInspector
{
    // null: not a managed assembly (native dll, resource-only file).
    public static AssemblyInfo? Read(string path)
    {
        using var stream = File.OpenRead(path);
        using var pe = new PEReader(stream);
        if (!pe.HasMetadata) return null;
        var md = pe.GetMetadataReader();
        if (!md.IsAssembly) return null;

        var def = md.GetAssemblyDefinition();
        string? tfm = null, informational = null;
        foreach (var h in def.GetCustomAttributes())
        {
            var attr = md.GetCustomAttribute(h);
            string attrName = AttributeTypeName(md, attr);
            if (attrName == "TargetFrameworkAttribute") tfm = FirstStringArg(attr);
            else if (attrName == "AssemblyInformationalVersionAttribute") informational = FirstStringArg(attr);
        }

        var refs = new List<(string, Version)>();
        foreach (var h in md.AssemblyReferences)
        {
            var r = md.GetAssemblyReference(h);
            refs.Add((md.GetString(r.Name), r.Version));
        }

        string? module = null, moduleVersion = null, pluginClass = null;
        int? minApi = null;
        foreach (var th in md.TypeDefinitions)
        {
            var type = md.GetTypeDefinition(th);
            if (!DerivesFromBasePlugin(md, type)) continue;
            pluginClass = md.GetString(type.Name);
            foreach (var ph in type.GetProperties())
            {
                var prop = md.GetPropertyDefinition(ph);
                string propName = md.GetString(prop.Name);
                if (propName is not ("ModuleName" or "ModuleVersion")) continue;
                var getter = prop.GetAccessors().Getter;
                if (getter.IsNil) continue;
                string? value = FirstLdstr(pe, md, md.GetMethodDefinition(getter))
                    ?? InitializerString(pe, md, type, $"<{propName}>k__BackingField");
                if (propName == "ModuleName") module = value;
                else moduleVersion = value;
            }
            foreach (var ah in type.GetCustomAttributes())
            {
                var attr = md.GetCustomAttribute(ah);
                if (AttributeTypeName(md, attr) is "MinimumApiVersion" or "MinimumApiVersionAttribute")
                    minApi = FirstIntArg(attr);
            }
            if (module != null) break;
        }

        return new AssemblyInfo
        {
            Path = path,
            Name = md.GetString(def.Name),
            Version = def.Version,
            InformationalVersion = informational,
            TargetFramework = tfm,
            TargetMajor = ParseTargetMajor(tfm),
            References = refs,
            ModuleName = module,
            ModuleVersion = moduleVersion,
            MinimumApiVersion = minApi,
            PluginClass = pluginClass,
        };
    }

    // ".NETCoreApp,Version=v8.0" -> 8; anything else (netstandard, framework) -> null.
    public static int? ParseTargetMajor(string? tfm)
    {
        if (tfm == null || !tfm.StartsWith(".NETCoreApp", StringComparison.Ordinal)) return null;
        int v = tfm.IndexOf("Version=v", StringComparison.Ordinal);
        if (v < 0) return null;
        string ver = tfm[(v + 9)..];
        int dot = ver.IndexOf('.');
        return int.TryParse(dot < 0 ? ver : ver[..dot], out int major) ? major : null;
    }

    // The direct base type is named BasePlugin (CounterStrikeSharp.API.Core.BasePlugin). Plugins that derive from
    // their own intermediate base class are found by the ModuleName property in a later pass if needed.
    private static bool DerivesFromBasePlugin(MetadataReader md, TypeDefinition type)
    {
        if (type.BaseType.IsNil) return false;
        if (type.BaseType.Kind == HandleKind.TypeReference)
        {
            var tr = md.GetTypeReference((TypeReferenceHandle)type.BaseType);
            return md.GetString(tr.Name) == "BasePlugin";
        }
        if (type.BaseType.Kind == HandleKind.TypeDefinition)
        {
            var td = md.GetTypeDefinition((TypeDefinitionHandle)type.BaseType);
            return DerivesFromBasePlugin(md, td);
        }
        return false;
    }

    // `public override string ModuleName => "Name";` compiles to ldstr <token>; ret. Return the first string literal.
    private static string? FirstLdstr(PEReader pe, MetadataReader md, MethodDefinition method)
    {
        if (method.RelativeVirtualAddress == 0) return null;
        var body = pe.GetMethodBody(method.RelativeVirtualAddress);
        var il = body.GetILBytes();
        if (il == null) return null;
        for (int i = 0; i + 4 < il.Length; i++)
        {
            if (il[i] != 0x72) continue;                               // ldstr
            int token = BitConverter.ToInt32(il, i + 1);
            if ((token >> 24) != 0x70) continue;                        // user string heap
            return md.GetUserString(MetadataTokens.UserStringHandle(token & 0x00FFFFFF));
        }
        return null;
    }

    // `public override string ModuleName { get; } = "Name";` sets the backing field in the constructor:
    // ldarg.0; ldstr <token>; stfld <ModuleName>k__BackingField. Find that ldstr.
    private static string? InitializerString(PEReader pe, MetadataReader md, TypeDefinition type, string field)
    {
        foreach (var mh in type.GetMethods())
        {
            var method = md.GetMethodDefinition(mh);
            if (md.GetString(method.Name) != ".ctor" || method.RelativeVirtualAddress == 0) continue;
            var il = pe.GetMethodBody(method.RelativeVirtualAddress).GetILBytes();
            if (il == null) continue;
            for (int i = 5; i + 4 < il.Length; i++)
            {
                if (il[i] != 0x7D || il[i - 5] != 0x72) continue;          // stfld preceded by ldstr
                int fieldToken = BitConverter.ToInt32(il, i + 1);
                if ((fieldToken >> 24) != 0x04) continue;                   // FieldDef
                var fd = md.GetFieldDefinition(MetadataTokens.FieldDefinitionHandle(fieldToken & 0x00FFFFFF));
                if (md.GetString(fd.Name) != field) continue;
                int strToken = BitConverter.ToInt32(il, i - 4);
                if ((strToken >> 24) != 0x70) continue;
                return md.GetUserString(MetadataTokens.UserStringHandle(strToken & 0x00FFFFFF));
            }
        }
        return null;
    }

    private static string AttributeTypeName(MetadataReader md, CustomAttribute attr)
    {
        if (attr.Constructor.Kind == HandleKind.MemberReference)
        {
            var mr = md.GetMemberReference((MemberReferenceHandle)attr.Constructor);
            if (mr.Parent.Kind == HandleKind.TypeReference)
                return md.GetString(md.GetTypeReference((TypeReferenceHandle)mr.Parent).Name);
        }
        else if (attr.Constructor.Kind == HandleKind.MethodDefinition)
        {
            var mdef = md.GetMethodDefinition((MethodDefinitionHandle)attr.Constructor);
            return md.GetString(md.GetTypeDefinition(mdef.GetDeclaringType()).Name);
        }
        return "";
    }

    private static string? FirstStringArg(CustomAttribute attr)
    {
        try
        {
            var value = attr.DecodeValue(new SimpleTypeProvider());
            return value.FixedArguments.Length > 0 ? value.FixedArguments[0].Value as string : null;
        }
        catch { return null; }
    }

    private static int? FirstIntArg(CustomAttribute attr)
    {
        try
        {
            var value = attr.DecodeValue(new SimpleTypeProvider());
            return value.FixedArguments.Length > 0 && value.FixedArguments[0].Value is int i ? i : null;
        }
        catch { return null; }
    }

    // Enough of ICustomAttributeTypeProvider to decode primitive and string attribute arguments.
    private sealed class SimpleTypeProvider : ICustomAttributeTypeProvider<Type>
    {
        public Type GetPrimitiveType(PrimitiveTypeCode typeCode) => typeCode switch
        {
            PrimitiveTypeCode.Boolean => typeof(bool),
            PrimitiveTypeCode.Byte => typeof(byte),
            PrimitiveTypeCode.Char => typeof(char),
            PrimitiveTypeCode.Double => typeof(double),
            PrimitiveTypeCode.Int16 => typeof(short),
            PrimitiveTypeCode.Int32 => typeof(int),
            PrimitiveTypeCode.Int64 => typeof(long),
            PrimitiveTypeCode.SByte => typeof(sbyte),
            PrimitiveTypeCode.Single => typeof(float),
            PrimitiveTypeCode.String => typeof(string),
            PrimitiveTypeCode.UInt16 => typeof(ushort),
            PrimitiveTypeCode.UInt32 => typeof(uint),
            PrimitiveTypeCode.UInt64 => typeof(ulong),
            _ => typeof(object),
        };
        public Type GetSystemType() => typeof(Type);
        public Type GetSZArrayType(Type elementType) => elementType.MakeArrayType();
        public Type GetTypeFromDefinition(MetadataReader reader, TypeDefinitionHandle handle, byte rawTypeKind) => typeof(int);
        public Type GetTypeFromReference(MetadataReader reader, TypeReferenceHandle handle, byte rawTypeKind) => typeof(int);
        public Type GetTypeFromSerializedName(string name) => typeof(Type);
        public PrimitiveTypeCode GetUnderlyingEnumType(Type type) => PrimitiveTypeCode.Int32;
        public bool IsSystemType(Type type) => type == typeof(Type);
    }
}
