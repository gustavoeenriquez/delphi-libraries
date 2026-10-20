# Muestras del decoder MP3

`synth_24k_mono_128k.mp3`: señal sintética de 4 s (barrido de 200 Hz en adelante, acorde de
440/660/1100 Hz y ruido), MPEG-2 Layer III, 24 kHz mono, 128 kb/s, sin cabecera Xing ni ID3.
Generada con:

    ffmpeg -f lavfi -i "aevalsrc='0.35*sin(2*PI*(200*t+300*t*t))*lt(t,2)+0.25*(sin(2*PI*440*t)+0.6*sin(2*PI*660*t)+0.4*sin(2*PI*1100*t))*gte(t,2)*lt(t,3.2)+0.2*(random(0)-0.5)*gte(t,3.2)':s=24000:d=4" -ac 1 -ar 24000 -c:a libmp3lame -b:a 128k -write_xing 0 -id3v2_version 0 synth_24k_mono_128k.mp3

Licencia: CC0 1.0, como el resto de las pruebas.
