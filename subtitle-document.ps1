function Get-LingoSubtitleSentences {
    param([string]$SourcePath)
    $text = [IO.File]::ReadAllText($SourcePath)
    $newline = [string][char]10
    $text = $text.Replace(([string][char]13 + $newline), $newline).Replace([string][char]13, $newline)
    $stamp = '\d+:\d{2}:\d{2}[,.]\d{3}'
    $cueTiming = "(?m)^[ \t]*$stamp[ \t]*-->[ \t]*$stamp[^\n]*\n"
    $markedTime = '\d{1,4}:\d{2}(?::\d{2})?(?:[,.]\d{1,3})?'
    $markedSpan = "$markedTime(?:[ \t]*(?:-->|[-–—])[ \t]*$markedTime)?"
    $dialogue = foreach ($block in [regex]::Split($text, '\n(?:[ \t]*\n)+')) {
        $time = [regex]::Match($block, $cueTiming)
        if (-not $time.Success) { continue }
        $body = [Net.WebUtility]::HtmlDecode($block.Substring($time.Index + $time.Length))
        $body = $body -replace "(?m)^[ \t]*$markedSpan[ \t]*$", ''
        $body = $body -replace "[\[<(][ \t]*$markedSpan[ \t]*[\])>]", ''
        $body = $body -replace '(?i)</?(?:i|b|u|font|v|c(?:\.[\w-]+)?|lang|ruby|rt)(?:[ \t]+[^<>]*)?>|\{\\[^{}]+\}', ''
        $body = ($body -replace '[\x00-\x08\x0b\x0c\x0e-\x1f]', '' -replace '\s+', ' ').Trim()
        if ($body) { $body }
    }

    # Captions can split a sentence across several cues, so join their text
    # before splitting on punctuation. Remove spaces introduced inside CJK text.
    $joined = $dialogue -join ' '
    $cjk = '[\u3000-\u30ff\u3400-\u9fff\uac00-\ud7af\uff00-\uffef]'
    $joined = $joined -replace "(?<=$cjk) +(?=$cjk)", ''
    $endings = '[.!?…。！？]+(?:[\u201d\u2019»」』】）)\]"'']|[ \t]+[»」』】）])*'
    $abbreviation = '(?i)(?:\b(?:m|mme|mmes|mlle|mr|mrs|ms|dr|pr|prof|st|ste|vs|fig|cf|no)\.|\b(?:[a-z]\.){2,})$'
    $offset = 0
    foreach ($match in [regex]::Matches($joined, $endings)) {
        $end = $match.Index + $match.Length
        if ($match.Value -notmatch '[。！？]' -and $end -lt $joined.Length -and -not [char]::IsWhiteSpace($joined[$end])) { continue }
        $sentence = $joined.Substring($offset, $end - $offset).Trim()
        if ($match.Value -eq '.' -and $sentence -match $abbreviation -and $end -lt $joined.Length) { continue }
        if ($sentence) { $sentence }
        $offset = $end
    }
    if ($offset -eq 0 -and @($dialogue).Count -gt 1) {
        $dialogue
        return
    }
    $remaining = $joined.Substring($offset).Trim()
    if ($remaining) { $remaining }
}

function Convert-LingoSubtitleToWord {
    param([string]$SourcePath, [string]$DestinationPath)
    $sentences = @(Get-LingoSubtitleSentences -SourcePath $SourcePath)
    if (-not $sentences.Count) { throw '所选字幕没有可导出到 Word 的正文。' }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $file = [IO.File]::Open($DestinationPath, [IO.FileMode]::Create)
    try {
        $package = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $parts = [ordered]@{
                '[Content_Types].xml' = '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
                '_rels/.rels' = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            }
            foreach ($part in $parts.GetEnumerator()) {
                $stream = $package.CreateEntry($part.Key).Open()
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes($part.Value)
                    $stream.Write($bytes, 0, $bytes.Length)
                } finally { $stream.Dispose() }
            }

            $stream = $package.CreateEntry('word/document.xml').Open()
            try {
                $writer = [Xml.XmlWriter]::Create($stream)
                try {
                    $word = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
                    $writer.WriteStartDocument()
                    $writer.WriteStartElement('w', 'document', $word)
                    $writer.WriteStartElement('w', 'body', $word)
                    foreach ($sentence in $sentences) {
                        $writer.WriteStartElement('w', 'p', $word)
                        $writer.WriteStartElement('w', 'pPr', $word)
                        $writer.WriteStartElement('w', 'spacing', $word)
                        $writer.WriteAttributeString('w', 'after', $word, '0')
                        $writer.WriteEndElement()
                        $writer.WriteEndElement()
                        $writer.WriteStartElement('w', 'r', $word)
                        $writer.WriteElementString('w', 't', $word, $sentence)
                        $writer.WriteEndElement()
                        $writer.WriteEndElement()
                    }
                    $writer.WriteEndDocument()
                } finally { $writer.Dispose() }
            } finally { $stream.Dispose() }
        } finally { $package.Dispose() }
    } finally { $file.Dispose() }
}

function Assert-LingoSubtitleWordDocument {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $package = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $document = $package.GetEntry('word/document.xml')
        if (-not $document -or -not $package.GetEntry('[Content_Types].xml') -or -not $package.GetEntry('_rels/.rels')) { throw 'Word 字幕文件结构不完整。' }
        $stream = $document.Open()
        try {
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $reader = [Xml.XmlReader]::Create($stream, $settings)
            try {
                $xml = [Xml.XmlDocument]::new()
                $xml.Load($reader)
                if (-not $xml.GetElementsByTagName('t', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main').Count) { throw 'Word 字幕文件没有正文。' }
            } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } finally { $package.Dispose() }
}
