function Test-Ed25519([byte[]]$Key, [byte[]]$Sig, [byte[]]$Message) {
    if ($Key.Length -ne 32 -or $Sig.Length -ne 64) { return $false }
    $BI = [System.Numerics.BigInteger]
    $Prime = $BI::Pow(2, 255) - 19
    $Order = $BI::Pow(2, 252) + $BI::Parse('27742317777372353535851937790883648493')
    function Mod([System.Numerics.BigInteger]$a) { $r = $a % $Prime; if ($r.Sign -lt 0) { $r + $Prime } else { $r } }
    function Inv([System.Numerics.BigInteger]$a) { $BI::ModPow((Mod $a), $Prime - 2, $Prime) }
    function FromLE([byte[]]$b) { $BI::new([byte[]]($b + [byte]0)) }
    $Coef = Mod ((Inv 121666) * -121665)
    $RootM1 = $BI::ModPow(2, ($Prime - 1) / 4, $Prime)
    function RecoverX([System.Numerics.BigInteger]$y, [int]$sign) {
        $y2 = Mod ($y * $y)
        $x2 = Mod (($y2 - 1) * (Inv ($Coef * $y2 + 1)))
        $x = $BI::ModPow($x2, ($Prime + 3) / 8, $Prime)
        if (-not (Mod ($x * $x - $x2)).IsZero) { $x = Mod ($x * $RootM1) }
        if (-not (Mod ($x * $x - $x2)).IsZero) { return $null }
        if ((-not $x.IsEven) -ne ($sign -eq 1)) { $x = $Prime - $x }
        $x
    }
    function Decode([byte[]]$b) {
        $top = $b[31]
        $c = [byte[]]$b.Clone(); $c[31] = $top -band 127
        $y = FromLE $c
        if ($y -ge $Prime) { return $null }
        $x = RecoverX $y ($top -shr 7)
        if ($null -eq $x) { return $null }
        , @($x, $y, $BI::One, (Mod ($x * $y)))
    }
    function Add-Point($p, $q) {
        $a = Mod (($p[1] - $p[0]) * ($q[1] - $q[0]))
        $b = Mod (($p[1] + $p[0]) * ($q[1] + $q[0]))
        $c = Mod ($p[3] * $q[3] * $Coef * 2)
        $d = Mod ($p[2] * $q[2] * 2)
        $e = $b - $a; $f = $d - $c; $g = $d + $c; $h = $b + $a
        , @((Mod ($e * $f)), (Mod ($g * $h)), (Mod ($f * $g)), (Mod ($e * $h)))
    }
    function Mul-Point([System.Numerics.BigInteger]$s, $pt) {
        $q = @($BI::Zero, $BI::One, $BI::One, $BI::Zero)
        $bytes = $s.ToByteArray()
        for ($i = $bytes.Length * 8 - 1; $i -ge 0; $i--) {
            $q = Add-Point $q $q
            if ((($bytes[[math]::Floor($i / 8)] -shr ($i % 8)) -band 1) -eq 1) { $q = Add-Point $q $pt }
        }
        $q
    }
    $By = Mod ((Inv 5) * 4)
    $Bx = RecoverX $By 0
    $BasePt = @($Bx, $By, $BI::One, (Mod ($Bx * $By)))
    $SigR = Decode $Sig[0..31]
    $PubA = Decode $Key
    $SigS = FromLE $Sig[32..63]
    if ($null -eq $SigR -or $null -eq $PubA -or $SigS -ge $Order) { return $false }
    $sha = [Security.Cryptography.SHA512]::Create()
    $h = (FromLE $sha.ComputeHash([byte[]]($Sig[0..31] + $Key + $Message))) % $Order
    $left = Mul-Point $SigS $BasePt
    $right = Add-Point $SigR (Mul-Point $h $PubA)
    (Mod ($left[0] * $right[2] - $right[0] * $left[2])).IsZero -and (Mod ($left[1] * $right[2] - $right[1] * $left[2])).IsZero
}
