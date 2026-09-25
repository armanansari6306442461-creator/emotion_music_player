$ErrorActionPreference = 'Stop'

$owner = 'armanansari6306442461-creator'
$repository = 'emotion_music_player'
$targetUser = 'armanansari6306442461-creator'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$branch = 'main'
$apiRoot = "https://api.github.com/repos/$owner/$repository"

$credentialInput = "protocol=https`nhost=github.com`nusername=$targetUser`n`n"
$credentialLines = $credentialInput | git credential fill
$tokenLine = $credentialLines | Where-Object { $_.StartsWith('password=') } | Select-Object -First 1
if (-not $tokenLine) { throw 'GitHub credential was unavailable.' }
$token = $tokenLine.Substring('password='.Length)

$headers = @{
    Authorization = "Bearer $token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'emotion-music-player-publisher'
}

$account = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 60
if ($account.login -ne $targetUser) { throw "GitHub authenticated as $($account.login), expected $targetUser." }

$currentRef = Invoke-RestMethod -Method Get -Uri "$apiRoot/git/ref/heads/$branch" -Headers $headers -TimeoutSec 60
$baseCommit = $currentRef.object.sha

$mediaFiles = @(
    @{ LocalPath = 'static/songs/angry/angry-video.mp4'; RepoPath = 'static/songs/angry/angry-video.mp4' },
    @{ LocalPath = 'static/songs/calm/calm1.mp3'; RepoPath = 'static/songs/calm/calm1.mp3' },
    @{ LocalPath = 'static/songs/happy/happy-video.mp4'; RepoPath = 'static/songs/happy/happy-video.mp4' },
    @{ LocalPath = 'static/songs/happy/happy1.mp3'; RepoPath = 'static/songs/happy/happy1.mp3' },
    @{ LocalPath = 'static/songs/sad/sad1.mp3'; RepoPath = 'static/songs/sad/sad1.mp3' }
)

$entries = @()
foreach ($media in $mediaFiles) {
    $localPath = Join-Path $scriptRoot $media.LocalPath
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        throw "Media file not found: $localPath"
    }

    $bytes = [IO.File]::ReadAllBytes($localPath)
    $content = [Convert]::ToBase64String($bytes)
    $blobBody = @{ content = $content; encoding = 'base64' } | ConvertTo-Json -Compress
    $requestFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($requestFile, $blobBody, [Text.UTF8Encoding]::new($false))
        $blobJson = & curl.exe --silent --show-error --request POST `
            --header "Authorization: Bearer $token" `
            --header 'Accept: application/vnd.github+json' `
            --header 'X-GitHub-Api-Version: 2022-11-28' `
            --header 'User-Agent: emotion-music-player-publisher' `
            --header 'Content-Type: application/json' `
            --data-binary "@$requestFile" `
            "$apiRoot/git/blobs"
        if ($LASTEXITCODE -ne 0) { throw "GitHub blob upload failed for $($media.RepoPath)." }
        $blob = $blobJson | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $requestFile -ErrorAction SilentlyContinue
    }
    $entries += @{ path = $media.RepoPath; mode = '100644'; type = 'blob'; sha = $blob.sha }
    Write-Output "Uploaded $($media.RepoPath)"
}

$baseTree = (git -C $scriptRoot rev-parse "$baseCommit^{tree}").Trim()
$treeBody = @{ base_tree = $baseTree; tree = $entries } | ConvertTo-Json -Depth 5 -Compress
$tree = Invoke-RestMethod -Method Post -Uri "$apiRoot/git/trees" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $treeBody -TimeoutSec 60

$commitBody = @{ message = 'Add music player media'; tree = $tree.sha; parents = @($baseCommit) } | ConvertTo-Json -Depth 5 -Compress
$commit = Invoke-RestMethod -Method Post -Uri "$apiRoot/git/commits" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $commitBody -TimeoutSec 60
$refBody = @{ sha = $commit.sha } | ConvertTo-Json -Compress
Invoke-RestMethod -Method Patch -Uri "$apiRoot/git/refs/heads/$branch" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $refBody -TimeoutSec 60 | Out-Null

$token = $null
$headers = $null
Write-Output "Published commit $($commit.sha)"
