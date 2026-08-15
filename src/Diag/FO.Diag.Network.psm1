<#
.SYNOPSIS
    Network latency diagnostics — the module that answers "why is my ping high".
.DESCRIPTION
    Three distinct questions get confused with each other constantly:

      1. "What is my baseline latency to the server?"
         Governed by physical distance and ISP routing. Largely not fixable.

      2. "How much does that latency vary?" (jitter)
         Governed by your local link, NIC settings, and Wi-Fi vs wired.
         Partly fixable, and jitter is what actually ruins build fights.

      3. "How much does my latency rise when the connection is busy?"
         This is BUFFERBLOAT, it is usually the real villain, it is very
         fixable, and almost nobody measures it.

    This module measures all three separately so you can tell which one you
    actually have.

    Measurement method: TCP connect time rather than ICMP echo. ICMP is
    frequently deprioritised or rate-limited by routers and is blocked outright
    by many, which makes ping.exe results unreliable and often pessimistic.
    A TCP handshake to port 443 traverses the same path as real traffic and is
    handled on the normal forwarding path.
#>

Set-StrictMode -Version Latest

# Epic hosts Fortnite's servers on AWS and GCP. These regional endpoints sit in
# the same datacentres and are the closest publicly reachable approximation of
# in-game ping that can be measured without being in a match.
$script:RegionEndpoints = @(
    @{ Region = 'NA-East';      Label = 'US East (Virginia)';   Host = 'ec2.us-east-1.amazonaws.com' }
    @{ Region = 'NA-Central';   Label = 'US East (Ohio)';       Host = 'ec2.us-east-2.amazonaws.com' }
    @{ Region = 'NA-West';      Label = 'US West (Oregon)';     Host = 'ec2.us-west-2.amazonaws.com' }
    @{ Region = 'EU-West';      Label = 'Europe (Ireland)';     Host = 'ec2.eu-west-1.amazonaws.com' }
    @{ Region = 'EU-London';    Label = 'Europe (London)';      Host = 'ec2.eu-west-2.amazonaws.com' }
    @{ Region = 'EU-Central';   Label = 'Europe (Frankfurt)';   Host = 'ec2.eu-central-1.amazonaws.com' }
    @{ Region = 'Brazil';       Label = 'South America';        Host = 'ec2.sa-east-1.amazonaws.com' }
    @{ Region = 'Oceania';      Label = 'Australia (Sydney)';   Host = 'ec2.ap-southeast-2.amazonaws.com' }
    @{ Region = 'Asia';         Label = 'Asia (Tokyo)';         Host = 'ec2.ap-northeast-1.amazonaws.com' }
    @{ Region = 'Middle-East';  Label = 'Middle East (Bahrain)';Host = 'ec2.me-south-1.amazonaws.com' }
)

function Measure-FOTcpLatency {
    <#
    .SYNOPSIS
        Measures TCP connect latency to a host, returning distribution statistics.
    .DESCRIPTION
        Reports minimum, median, mean, maximum and jitter. The MINIMUM is the
        closest thing to your true path latency — it is the sample least
        contaminated by queuing. The spread between min and max is jitter, and
        jitter is what you feel as inconsistency.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TargetHost,
        [int] $Port = 443,
        [int] $Samples = 10,
        [int] $TimeoutMs = 2000
    )

    $times = [System.Collections.ArrayList]::new()
    $failures = 0

    for ($i = 0; $i -lt $Samples; $i++) {
        $client = $null
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.NoDelay = $true

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
            $completed = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

            if ($completed -and $client.Connected) {
                $sw.Stop()
                $client.EndConnect($async)
                $null = $times.Add($sw.Elapsed.TotalMilliseconds)
            } else {
                $failures++
            }
        } catch {
            $failures++
        } finally {
            if ($client) { $client.Close(); $client.Dispose() }
        }

        # Brief gap so consecutive probes do not queue behind each other.
        Start-Sleep -Milliseconds 60
    }

    if ($times.Count -eq 0) {
        return [pscustomobject]@{
            TargetHost = $TargetHost; Reachable = $false; Samples = 0; Failures = $failures
            MinMs = $null; MedianMs = $null; MeanMs = $null; MaxMs = $null; JitterMs = $null
        }
    }

    $sorted = @($times | Sort-Object)
    $median = if ($sorted.Count % 2 -eq 1) {
        $sorted[[math]::Floor($sorted.Count / 2)]
    } else {
        ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2
    }

    $mean = ($sorted | Measure-Object -Average).Average

    # Jitter as mean absolute deviation between consecutive samples — this
    # matches how network engineers define it, and reflects what the game's
    # interpolation actually has to cope with.
    $deltas = for ($i = 1; $i -lt $times.Count; $i++) {
        [math]::Abs($times[$i] - $times[$i - 1])
    }
    $jitter = if ($deltas) { ($deltas | Measure-Object -Average).Average } else { 0 }

    return [pscustomobject]@{
        TargetHost = $TargetHost
        Reachable  = $true
        Samples    = $times.Count
        Failures   = $failures
        MinMs      = [math]::Round($sorted[0], 1)
        MedianMs   = [math]::Round($median, 1)
        MeanMs     = [math]::Round($mean, 1)
        MaxMs      = [math]::Round($sorted[-1], 1)
        JitterMs   = [math]::Round($jitter, 1)
    }
}

function Test-FORegionLatency {
    <#
    .SYNOPSIS
        Measures latency to every Fortnite region so you can confirm you are
        being matched to the right one.
    #>
    [CmdletBinding()]
    param([int] $Samples = 6)

    Write-FOLog -Level Info -Message 'Measuring latency to each Fortnite region (this takes a minute)...'
    $results = [System.Collections.ArrayList]::new()

    foreach ($endpoint in $script:RegionEndpoints) {
        Write-Host "  probing $($endpoint.Region)..." -ForegroundColor DarkGray
        $measure = Measure-FOTcpLatency -TargetHost $endpoint.Host -Samples $Samples

        $null = $results.Add([pscustomobject]@{
            Region    = $endpoint.Region
            Label     = $endpoint.Label
            Reachable = $measure.Reachable
            MinMs     = $measure.MinMs
            MedianMs  = $measure.MedianMs
            JitterMs  = $measure.JitterMs
        })
    }

    return @($results | Sort-Object { if ($null -eq $_.MinMs) { [double]::MaxValue } else { $_.MinMs } })
}

function Test-FOBufferbloat {
    <#
    .SYNOPSIS
        Measures how far latency rises when the connection is saturated.
    .DESCRIPTION
        This is the test that matters most and that almost nobody runs.

        Bufferbloat is oversized buffers in your router or modem. When anything
        saturates the link — a Windows update, a game patch downloading, someone
        else in the house streaming — packets queue in those buffers instead of
        being dropped. Your game packets sit in that queue. Ping goes from 30ms
        to 300ms and the game becomes unplayable, while every speed test still
        reports the connection as fine.

        A rise of more than about 50ms under load is a real problem, and the fix
        is at the router (SQM / QoS / cake or fq_codel), not on the PC.
    #>
    [CmdletBinding()]
    param(
        [string] $LatencyTarget = '1.1.1.1',
        [string] $LoadUrl = 'https://speed.cloudflare.com/__down?bytes=200000000',
        [int] $LoadSeconds = 12
    )

    Write-FOLog -Level Info -Message 'Measuring idle latency baseline...'
    $idle = Measure-FOTcpLatency -TargetHost $LatencyTarget -Samples 12

    if (-not $idle.Reachable) {
        Write-FOLog -Level Warn -Message 'Could not reach latency target; bufferbloat test skipped'
        return [pscustomobject]@{ Success = $false; Reason = "Could not reach $LatencyTarget" }
    }

    Write-FOLog -Level Info -Message "Saturating the connection for $LoadSeconds seconds and re-measuring..."

    # Start a background download to fill the downstream buffer.
    $job = Start-Job -ScriptBlock {
        param($url, $seconds)
        try {
            $request = [System.Net.HttpWebRequest]::Create($url)
            $request.Timeout = ($seconds + 10) * 1000
            $response = $request.GetResponse()
            $stream = $response.GetResponseStream()
            $buffer = New-Object byte[] 65536
            $deadline = (Get-Date).AddSeconds($seconds)
            while ((Get-Date) -lt $deadline) {
                if ($stream.Read($buffer, 0, $buffer.Length) -le 0) { break }
            }
            $stream.Close(); $response.Close()
        } catch { }
    } -ArgumentList $LoadUrl, $LoadSeconds

    # Give the download a moment to ramp up and actually fill the buffer before
    # sampling — measuring too early understates the problem.
    Start-Sleep -Seconds 3
    $loaded = Measure-FOTcpLatency -TargetHost $LatencyTarget -Samples 12

    Wait-Job -Job $job -Timeout ($LoadSeconds + 15) | Out-Null
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    $increase = $loaded.MedianMs - $idle.MedianMs

    $grade = if ($increase -lt 5)   { 'A+' }
             elseif ($increase -lt 30)  { 'A'  }
             elseif ($increase -lt 60)  { 'B'  }
             elseif ($increase -lt 200) { 'C'  }
             elseif ($increase -lt 400) { 'D'  }
             else { 'F' }

    return [pscustomobject]@{
        Success        = $true
        IdleMedianMs   = $idle.MedianMs
        IdleMinMs      = $idle.MinMs
        LoadedMedianMs = $loaded.MedianMs
        LoadedMaxMs    = $loaded.MaxMs
        IncreaseMs     = [math]::Round($increase, 1)
        Grade          = $grade
        JitterIdleMs   = $idle.JitterMs
        JitterLoadedMs = $loaded.JitterMs
    }
}

function Test-FODoubleNat {
    <#
    .SYNOPSIS
        Detects double-NAT by counting private-address hops on the path out.
    #>
    [CmdletBinding()]
    param([string] $TargetHost = '1.1.1.1', [int] $MaxHops = 6)

    Write-FOLog -Level Info -Message 'Tracing the first few hops to check for double-NAT...'

    $privateHops = [System.Collections.ArrayList]::new()
    $reachedPublic = $false

    try {
        $trace = tracert -d -h $MaxHops -w 1200 $TargetHost 2>$null

        foreach ($line in $trace) {
            if ($line -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') {
                $ip = $Matches[1]
                if ($ip -eq $TargetHost) { continue }

                if (Test-FOPrivateAddress -Address $ip) {
                    if (-not $reachedPublic -and $privateHops -notcontains $ip) {
                        $null = $privateHops.Add($ip)
                    }
                } else {
                    $reachedPublic = $true
                }
            }
        }
    } catch {
        Write-FOLog -Level Warn -Message 'Traceroute failed' -Data @{ error = $_.Exception.Message }
    }

    # Also compare the local gateway against the WAN address the first hop uses.
    $gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1).NextHop

    return [pscustomobject]@{
        PrivateHopCount = $privateHops.Count
        PrivateHops     = $privateHops.ToArray()
        Gateway         = $gateway
        IsDoubleNat     = ($privateHops.Count -ge 2)
    }
}

function Test-FOPrivateAddress {
    param([Parameter(Mandatory)] [string] $Address)

    try {
        $bytes = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    } catch { return $false }

    # RFC1918 plus CGNAT (100.64/10), which ISPs increasingly use and which
    # produces the same symptoms as a second NAT layer.
    if ($bytes[0] -eq 10) { return $true }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
    if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return $true }
    return $false
}

function Get-FONetworkReport {
    <#
    .SYNOPSIS
        Runs the full network diagnostic and interprets it in plain language.
    #>
    [CmdletBinding()]
    param([switch] $SkipRegions, [switch] $SkipBufferbloat)

    $lines = [System.Collections.ArrayList]::new()
    $null = $lines.Add('NETWORK DIAGNOSTIC')
    $null = $lines.Add('=' * 72)

    # --- Link ---------------------------------------------------------------
    $adapter = Get-FOPrimaryAdapter
    if ($adapter) {
        $null = $lines.Add("Adapter    : $($adapter.InterfaceDescription)")
        $null = $lines.Add("Link speed : $($adapter.LinkSpeed)")

        $isWireless = ($adapter.PhysicalMediaType -match 'Wireless' -or $adapter.MediaType -eq 'Native 802.11')
        if ($isWireless) {
            $null = $lines.Add('')
            $null = $lines.Add('  [CRITICAL] You are on Wi-Fi, not ethernet.')
            $null = $lines.Add('        Wi-Fi adds jitter that no software tweak can remove. Use a cable.')
        }
        if ($adapter.LinkSpeed -match '^100 Mbps') {
            $null = $lines.Add('')
            $null = $lines.Add('  [WARN] The link negotiated at 100 Mbps rather than 1 Gbps.')
            $null = $lines.Add('        This usually means a damaged cable or a bad port. Bandwidth is')
            $null = $lines.Add('        not your problem, but a cable degraded enough to drop to 100')
            $null = $lines.Add('        Mbps is often also producing errors and retransmits, which is.')
        }
    }
    $null = $lines.Add('')

    # --- Double NAT ---------------------------------------------------------
    $nat = Test-FODoubleNat
    $null = $lines.Add("Gateway    : $($nat.Gateway)")
    $null = $lines.Add("Private hops before reaching a public address: $($nat.PrivateHopCount)")
    if ($nat.IsDoubleNat) {
        $null = $lines.Add('')
        $null = $lines.Add('  [INFO] Double-NAT confirmed — two layers of private addressing.')
        foreach ($wrapped in (Split-FOText -Width 66 -Text "Be careful how much you blame this. A second NAT hop typically adds one to three milliseconds, not thirty. It does not explain a high-30s ping. What it genuinely can cause is Fortnite reporting a strict or moderate NAT type, occasional trouble with voice chat, and slower peer connection setup. If you want to fix it properly, put the outer router into bridge or modem mode so only one device performs NAT. Do not expect your ping number to move much.")) {
            $null = $lines.Add("        $wrapped")
        }
    }
    $null = $lines.Add('')

    # --- Bufferbloat --------------------------------------------------------
    if (-not $SkipBufferbloat) {
        $bloat = Test-FOBufferbloat
        if ($bloat.Success) {
            $null = $lines.Add('BUFFERBLOAT')
            $null = $lines.Add('-' * 72)
            $null = $lines.Add("  Idle latency        : $($bloat.IdleMedianMs) ms (best sample $($bloat.IdleMinMs) ms)")
            $null = $lines.Add("  Latency under load  : $($bloat.LoadedMedianMs) ms (worst $($bloat.LoadedMaxMs) ms)")
            $null = $lines.Add("  Increase under load : +$($bloat.IncreaseMs) ms")
            $null = $lines.Add("  Grade               : $($bloat.Grade)")
            $null = $lines.Add('')

            $verdict = if ($bloat.IncreaseMs -lt 30) {
                "Your connection holds up well under load. Bufferbloat is not your problem, which means the delay you are feeling is on the PC side rather than the network side — look at the frame cap and GPU utilisation instead."
            } elseif ($bloat.IncreaseMs -lt 100) {
                "Moderate bufferbloat. Your latency roughly doubles when anything else is downloading. If your delay feels worst when the Epic launcher is patching or someone else is streaming, this is why. Enabling Smart Queue Management (SQM/QoS) on your primary router will fix it."
            } else {
                "SEVERE bufferbloat. This is very likely a major contributor to what you are experiencing, and it is entirely fixable. Under load your latency rises by $($bloat.IncreaseMs) ms, which is far larger than anything the tweaks in this tool can address. Fix it at the router: enable SQM or QoS (look for 'cake' or 'fq_codel'), and set the bandwidth limits to roughly 85-90 percent of your measured speed. With double-NAT, apply this on whichever router actually connects to the internet."
            }
            foreach ($wrapped in (Split-FOText -Width 68 -Text $verdict)) {
                $null = $lines.Add("  $wrapped")
            }
            $null = $lines.Add('')
        }
    }

    # --- Region matrix ------------------------------------------------------
    if (-not $SkipRegions) {
        $regions = Test-FORegionLatency
        $null = $lines.Add('REGION LATENCY')
        $null = $lines.Add('-' * 72)
        $null = $lines.Add(('  {0,-13} {1,-24} {2,>9} {3,>9}' -f 'Region', 'Datacentre', 'Best ms', 'Jitter'))

        foreach ($r in $regions) {
            $best = if ($r.Reachable) { "$($r.MinMs)" } else { 'unreachable' }
            $jit  = if ($r.Reachable) { "$($r.JitterMs)" } else { '-' }
            $null = $lines.Add(('  {0,-13} {1,-24} {2,>9} {3,>9}' -f $r.Region, $r.Label, $best, $jit))
        }
        $null = $lines.Add('')

        $closest = $regions | Where-Object { $_.Reachable } | Select-Object -First 1
        if ($closest) {
            foreach ($wrapped in (Split-FOText -Width 68 -Text "Your closest region is $($closest.Region) at roughly $($closest.MinMs) ms. If Fortnite is putting you in a different region than this one, change it in the game's matchmaking region setting — playing on the wrong region is the one ping problem that genuinely is fixable in software, and it costs nothing to check. If Fortnite already matches you to $($closest.Region), then your ping is essentially distance to the datacentre, and no tweak, config or 'ping booster' will meaningfully reduce it. Anything advertising otherwise is selling you a slower route with extra steps.")) {
                $null = $lines.Add("  $wrapped")
            }
        }
    }

    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function `
    Measure-FOTcpLatency, Test-FORegionLatency, Test-FOBufferbloat, `
    Test-FODoubleNat, Test-FOPrivateAddress, Get-FONetworkReport
