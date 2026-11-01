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
    param([int[]]$SwiperIds)

    if (-not $SwiperIds -or $SwiperIds.Count -eq 0) { return @() }

    $ids = $SwiperIds -join ","
    $query = @"
SELECT Swiper_Id, Game_Id, LastComms, Status
FROM Swiper_Units
WHERE Swiper_Id IN ($ids)
"@

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Server=$($Settings.SqlServer);Database=$($Settings.Database);Integrated Security=True"
    $connection.Open()

    $command = $connection.CreateCommand()
    $command.CommandText = $query

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $table = New-Object System.Data.DataTable
    $adapter.Fill($table) | Out-Null

    $connection.Close()
    return $table
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

    if (-not $LastComms) { return "Dead" }

    $age = (Get-Date) - $LastComms

    if ($age.TotalSeconds -lt 10) { return "Fresh" }
    if ($age.TotalSeconds -lt 60) { return "Stale" }
    return "Dead"
}

# ============================
# DYNAMIC ELC STATUS
# ============================

function Get-ELCStatus {
    param($ELC)

    $segmentResults = @()

    foreach ($port in $ELC.Ports) {
        $portOpen = Test-Port -IP $ELC.IP -Port $port

        # Dynamic: pull all swipers for this location (simplified: use all)
        # In a real version you’d filter by Location_Id or Game_Id pattern.
        $sqlData = Get-SwiperData -SwiperIds @(29,82,93,113,116,117)  # your known swipers

        $lastComms = $sqlData.LastComms | Sort-Object -Descending | Select-Object -First 1
        $heartbeat = Get-HeartbeatStatus -LastComms $lastComms

        $segmentResults += [PSCustomObject]@{
            PortOpen  = $portOpen
            Heartbeat = $heartbeat
        }
    }

    $overallStatus =
        if ($segmentResults.PortOpen -contains $true) { "Online" } else { "Offline" }

    $overallHeartbeat =
        if ($segmentResults.Heartbeat -contains "Fresh") { "Fresh" }
        elseif ($segmentResults.Heartbeat -contains "Stale") { "Stale" }
        else { "Dead" }

    $segmentsOK =
        if ($segmentResults.Heartbeat -contains "Dead") { "Issues Detected" }
        else { "OK" }

    return [PSCustomObject]@{
        Name      = $ELC.Name
        IP        = $ELC.IP
        Status    = $overallStatus
        Heartbeat = $overallHeartbeat
        Segments  = $segmentsOK
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

    foreach ($elc in $Settings.ELCs) {
        $status = Get-ELCStatus -ELC $elc

$block = New-Object System.Windows.Controls.TextBlock
$block.Margin = "0,0,0,20"
$block.FontSize = 20

# Determine colors
$statusColor = if ($status.Status -eq "Online") { "LightGreen" } else { "Red" }
$heartbeatColor = switch ($status.Heartbeat) {
    "Fresh" { "LightGreen" }
    "Stale" { "Yellow" }
    default { "Red" }
}
$segmentsColor = if ($status.Segments -eq "OK") { "LightGreen" } else { "Red" }

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
