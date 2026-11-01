Add-Type -AssemblyName PresentationFramework

# ============================
# DEFAULT SETTINGS
# ============================

$Settings = [PSCustomObject]@{
    SqlServer   = "ECSSERVER"
    Database    = "ECS7"
    RefreshMs   = 2000
    ELCs        = @(
        [PSCustomObject]@{ Name="ELC1"; IP="192.168.101.211"; Ports=@(7771,7772,7773,7774) },
        [PSCustomObject]@{ Name="ELC2"; IP="192.168.101.213"; Ports=@(7771,7772,7773,7774) }
    )
}

# ============================
# SQL QUERY
# ============================

function Get-SwiperData {
    param()

    $query = @"
SELECT Swiper_Id, Polling_Group, LastComms
FROM Swiper_Units
WHERE Polling_Group IN ('A', 'B', 'C', 'D')
"@

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Server=$($Settings.SqlServer);Database=$($Settings.Database);Integrated Security=True"

    try {
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = $query

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
        $table = New-Object System.Data.DataTable
        $adapter.Fill($table) | Out-Null

        return $table
    }
    finally {
        if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
            $connection.Close()
        }
        $connection.Dispose()
    }
}

# ============================
# PORT CHECK
# ============================

function Test-Port {
    param($IP, $Port)

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $result = $client.BeginConnect($IP, $Port, $null, $null)
        $wait = $result.AsyncWaitHandle.WaitOne(300)
        if ($wait -and $client.Connected) {
            $client.EndConnect($result)
            $client.Close()
            return $true
        }
    } catch {}
    return $false
}

# ============================
# HEARTBEAT CLASSIFICATION
# ============================

function Get-HeartbeatStatus {
    param($LastComms)

    if ($null -eq $LastComms -or $LastComms -is [DBNull]) { return "Dead" }

    $age = (Get-Date) - $LastComms

    if ($age.TotalSeconds -lt 10) { return "Fresh" }
    if ($age.TotalSeconds -lt 60) { return "Stale" }
    return "Dead"
}

# ============================
# DYNAMIC ELC STATUS
# ============================

function Get-ELCStatus {
    param($ELC, $SegmentData)

    $segmentResults = @()

    foreach ($port in $ELC.Ports) {
        $portOpen = Test-Port -IP $ELC.IP -Port $port

        $segmentResults += [PSCustomObject]@{
            PortOpen  = $portOpen
        }
    }

    $segmentHealth = foreach ($segmentName in @("A", "B", "C", "D")) {
        $readers = @()
        if ($SegmentData.ContainsKey($segmentName)) {
            $readers = @($SegmentData[$segmentName])
        }
        $readerHealth = @($readers | ForEach-Object {
            [PSCustomObject]@{
                SwiperId  = $_.SwiperId
                Heartbeat = Get-HeartbeatStatus -LastComms $_.LastComms
            }
        })

        $heartbeat =
            if ($readerHealth.Count -eq 0 -or $readerHealth.Heartbeat -contains "Dead") { "Dead" }
            elseif ($readerHealth.Heartbeat -contains "Stale") { "Stale" }
            else { "Fresh" }

        $readerSummary =
            if ($readerHealth.Count -eq 0) { "No readers" }
            else { ($readerHealth | ForEach-Object { "$($_.SwiperId) $($_.Heartbeat)" }) -join ", " }

        [PSCustomObject]@{
            Name          = $segmentName
            Heartbeat     = $heartbeat
            ReaderSummary = $readerSummary
        }
    }

    $overallStatus =
        if ($segmentResults.PortOpen -contains $true) { "Online" } else { "Offline" }

    $overallHeartbeat =
        if ($segmentHealth.Heartbeat -contains "Dead") { "Dead" }
        elseif ($segmentHealth.Heartbeat -contains "Stale") { "Stale" }
        else { "Fresh" }

    $segmentsSummary =
        ($segmentHealth | ForEach-Object { "$($_.Name): $($_.ReaderSummary)" }) -join "; "

    return [PSCustomObject]@{
        Name      = $ELC.Name
        IP        = $ELC.IP
        Status    = $overallStatus
        Heartbeat = $overallHeartbeat
        Segments  = $segmentsSummary
    }
}

# ============================
# XAML UI (Sidebar + Main)
# ============================

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="ELC Dashboard v3.2 — Dynamic Auto-Detect"
        Width="500" Height="525" WindowStartupLocation="CenterScreen"
        Background="#222222" Foreground="White" FontSize="16">

  <Grid>
    <Grid.ColumnDefinitions>
        <ColumnDefinition Width="240" />
        <ColumnDefinition Width="*" />
    </Grid.ColumnDefinitions>

    <!-- LEFT SIDEBAR -->
    <StackPanel Grid.Column="0" Background="#333333" Margin="5">
        <TextBlock Text="Settings" FontSize="20" Margin="5" />

        <TextBlock Text="SQL Server:" Margin="5" />
        <TextBox Name="SqlServerBox" Margin="5" />

        <TextBlock Text="Refresh (ms):" Margin="5" />
        <TextBox Name="RefreshBox" Margin="5" />

        <TextBlock Text="ELC1 IP:" Margin="5" />
        <TextBox Name="ELC1IPBox" Margin="5" />

        <TextBlock Text="ELC1 Ports (comma):" Margin="5" />
        <TextBox Name="ELC1PortsBox" Margin="5" />

        <TextBlock Text="ELC2 IP:" Margin="5" />
        <TextBox Name="ELC2IPBox" Margin="5" />

        <TextBlock Text="ELC2 Ports (comma):" Margin="5" />
        <TextBox Name="ELC2PortsBox" Margin="5" />

        <Button Name="ApplyButton" Content="Apply Settings" Margin="5" Height="30" />
    </StackPanel>

    <!-- MAIN PANEL (NO SCROLL BAR) -->
    <StackPanel Grid.Column="1" Margin="20" Name="ELCPanel" />
</Grid>

</Window>
"@


$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$ELCPanel     = $window.FindName("ELCPanel")
$SqlServerBox = $window.FindName("SqlServerBox")
$RefreshBox   = $window.FindName("RefreshBox")
$ELC1IPBox    = $window.FindName("ELC1IPBox")
$ELC1PortsBox = $window.FindName("ELC1PortsBox")
$ELC2IPBox    = $window.FindName("ELC2IPBox")
$ELC2PortsBox = $window.FindName("ELC2PortsBox")
$ApplyButton  = $window.FindName("ApplyButton")

# Initialize sidebar fields
$SqlServerBox.Text = $Settings.SqlServer
$RefreshBox.Text   = $Settings.RefreshMs.ToString()
$ELC1IPBox.Text    = $Settings.ELCs[0].IP
$ELC1PortsBox.Text = ($Settings.ELCs[0].Ports -join ",")
$ELC2IPBox.Text    = $Settings.ELCs[1].IP
$ELC2PortsBox.Text = ($Settings.ELCs[1].Ports -join ",")

# ============================
# RENDER FUNCTION
# ============================

function Render-ELCs {
    $ELCPanel.Children.Clear()
    $sqlData = Get-SwiperData
    $segmentData = @{}
    foreach ($row in $sqlData.Rows) {
        $group = [string]$row.Polling_Group
        if (-not $segmentData.ContainsKey($group)) {
            $segmentData[$group] = @()
        }
        $segmentData[$group] += [PSCustomObject]@{
            SwiperId  = $row.Swiper_Id
            LastComms = $row.LastComms
        }
    }

    foreach ($elc in $Settings.ELCs) {
        $status = Get-ELCStatus -ELC $elc -SegmentData $segmentData

$block = New-Object System.Windows.Controls.TextBlock
$block.Margin = "0,0,0,20"
$block.FontSize = 20
$block.TextWrapping = "Wrap"

# Determine colors
$statusColor = if ($status.Status -eq "Online") { "LightGreen" } else { "Red" }
$heartbeatColor = switch ($status.Heartbeat) {
    "Fresh" { "LightGreen" }
    "Stale" { "Yellow" }
    default { "Red" }
}
$segmentsColor = if ($status.Segments -match "Dead") { "Red" } elseif ($status.Segments -match "Stale") { "Yellow" } else { "LightGreen" }

# Build inline formatted text
$block.Inlines.Add("$( $status.Name ) ($($status.IP))`n")

$block.Inlines.Add("  Status: ")
$run1 = New-Object System.Windows.Documents.Run($status.Status)
$run1.Foreground = $statusColor
$block.Inlines.Add($run1)
$block.Inlines.Add("`n")

$block.Inlines.Add("  Heartbeat: ")
$run2 = New-Object System.Windows.Documents.Run($status.Heartbeat)
$run2.Foreground = $heartbeatColor
$block.Inlines.Add($run2)
$block.Inlines.Add("`n")

$block.Inlines.Add("  Segments: ")
$run3 = New-Object System.Windows.Documents.Run($status.Segments)
$run3.Foreground = $segmentsColor
$block.Inlines.Add($run3)

$ELCPanel.Children.Add($block)

    }
}

# ============================
# APPLY SETTINGS HANDLER
# ============================

$ApplyButton.Add_Click({
    $Settings.SqlServer = $SqlServerBox.Text
    [int]$Settings.RefreshMs = [int]$RefreshBox.Text

    $Settings.ELCs[0].IP    = $ELC1IPBox.Text
    $Settings.ELCs[0].Ports = $ELC1PortsBox.Text.Split(",") | ForEach-Object { [int]$_ }

    $Settings.ELCs[1].IP    = $ELC2IPBox.Text
    $Settings.ELCs[1].Ports = $ELC2PortsBox.Text.Split(",") | ForEach-Object { [int]$_ }

    Render-ELCs
})

# ============================
# TIMER FOR REFRESH
# ============================

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($Settings.RefreshMs)
$timer.Add_Tick({
    Render-ELCs
})
$timer.Start()

# Initial render
Render-ELCs

$window.ShowDialog()
