$ErrorActionPreference='Stop'
 $root=Split-Path -Parent $PSScriptRoot
$tempRoot=Join-Path $env:TEMP ('lingosave-cover-validation-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$script:ffprobePath='E:\ffmpeg\bin\ffprobe.exe'
$ffmpeg='E:\ffmpeg\bin\ffmpeg.exe'
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'resource-worker.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw $errors[0]}
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-AssetOutput'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
. (Join-Path $root 'resource-pipeline.ps1')
function Assert-Cover {param([bool]$Condition,[string]$Message);if(-not$Condition){throw $Message};Write-Host ('PASS '+$Message)}
function Test-Rejected {param([string]$Path,[string]$Type);try{Test-AssetOutput -Path $Path -Type $Type;return $false}catch{return $true}}
try{
 $plain=Join-Path $tempRoot 'plain.mp3';$cover=Join-Path $tempRoot 'cover.jpg';$covered=Join-Path $tempRoot 'covered.mp3';$video=Join-Path $tempRoot 'video.mp4'
 & $ffmpeg -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:duration=1' -c:a libmp3lame -y $plain
 if($LASTEXITCODE){throw 'Audio fixture failed'}
 & $ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=green:s=64x64' -frames:v 1 -threads 1 -y $cover
 if($LASTEXITCODE){throw 'Cover fixture failed'}
 & $ffmpeg -hide_banner -loglevel error -i $plain -i $cover -map '0:a' -map '1:v' -c copy -disposition:v attached_pic -id3v2_version 3 -y $covered
 if($LASTEXITCODE){throw 'Covered fixture failed'}
 & $ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=64x64:r=12:d=1' -i $plain -c:v libx264 -c:a aac -shortest -y $video
 if($LASTEXITCODE){throw 'Video fixture failed'}
 Test-AssetOutput -Path $plain -Type audio;Assert-Cover $true 'plain MP3 remains accepted'
 Test-AssetOutput -Path $covered -Type audio;Assert-Cover $true 'MP3 plus embedded cover is valid audio'
 Assert-Cover (Test-Rejected $video audio) 'real video with sound is still rejected as standalone audio'
 Assert-Cover (Test-Rejected $cover audio) 'cover image without audio is rejected'
 Assert-Cover (Test-Rejected $covered video) 'audio cover cannot satisfy complete video validation'
 Test-AssetOutput -Path $video -Type video;Assert-Cover $true 'complete moving video with audio remains accepted'
 Assert-Cover (-not(Test-LingoRawMedia -Path $covered -Format @{vcodec='h264';acodec='mp3'})) 'raw video cache cannot mistake a cover for video'
 Assert-Cover (Test-LingoRawMedia -Path $covered -Format @{vcodec='none';acodec='mp3'}) 'original radio audio cache with cover remains reusable'
}finally{
 $resolved=[IO.Path]::GetFullPath($tempRoot);$allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
 if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)-and [IO.Path]::GetFileName($resolved).StartsWith('lingosave-cover-validation-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
