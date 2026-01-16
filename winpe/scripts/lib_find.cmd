@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ------------------------------------------------------------------
REM find_os_drive  -> sets OS_DRIVE like C:
REM Criteria: \Windows\System32\Config\SYSTEM exists
REM ------------------------------------------------------------------
:find_os_drive
set "OS_DRIVE="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist "%%D:\Windows\System32\Config\SYSTEM" (
    set "OS_DRIVE=%%D:"
    goto :eof
  )
)
goto :eof

REM ------------------------------------------------------------------
REM find_virtio_root -> sets VIRTIO_DRIVE like D: and VIRTIO_ROOT like D:\
REM Criteria: driver folders exist under root
REM ------------------------------------------------------------------
:find_virtio_root
set "VIRTIO_DRIVE="
set "VIRTIO_ROOT="

for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist "%%D:\vioscsi\"  goto :virtio_found_%%D
  if exist "%%D:\viostor\"  goto :virtio_found_%%D
  if exist "%%D:\vioserial\" goto :virtio_found_%%D
  if exist "%%D:\NetKVM\"   goto :virtio_found_%%D
  if exist "%%D:\Balloon\"  goto :virtio_found_%%D
)

goto :eof

:virtio_found_C
set "VIRTIO_DRIVE=C:"
set "VIRTIO_ROOT=C:\"
goto :eof
:virtio_found_D
set "VIRTIO_DRIVE=D:"
set "VIRTIO_ROOT=D:\"
goto :eof
:virtio_found_E
set "VIRTIO_DRIVE=E:"
set "VIRTIO_ROOT=E:\"
goto :eof
:virtio_found_F
set "VIRTIO_DRIVE=F:"
set "VIRTIO_ROOT=F:\"
goto :eof
:virtio_found_G
set "VIRTIO_DRIVE=G:"
set "VIRTIO_ROOT=G:\"
goto :eof
:virtio_found_H
set "VIRTIO_DRIVE=H:"
set "VIRTIO_ROOT=H:\"
goto :eof
:virtio_found_I
set "VIRTIO_DRIVE=I:"
set "VIRTIO_ROOT=I:\"
goto :eof
:virtio_found_J
set "VIRTIO_DRIVE=J:"
set "VIRTIO_ROOT=J:\"
goto :eof
:virtio_found_K
set "VIRTIO_DRIVE=K:"
set "VIRTIO_ROOT=K:\"
goto :eof
:virtio_found_L
set "VIRTIO_DRIVE=L:"
set "VIRTIO_ROOT=L:\"
goto :eof
:virtio_found_M
set "VIRTIO_DRIVE=M:"
set "VIRTIO_ROOT=M:\"
goto :eof
:virtio_found_N
set "VIRTIO_DRIVE=N:"
set "VIRTIO_ROOT=N:\"
goto :eof
:virtio_found_O
set "VIRTIO_DRIVE=O:"
set "VIRTIO_ROOT=O:\"
goto :eof
:virtio_found_P
set "VIRTIO_DRIVE=P:"
set "VIRTIO_ROOT=P:\"
goto :eof
:virtio_found_Q
set "VIRTIO_DRIVE=Q:"
set "VIRTIO_ROOT=Q:\"
goto :eof
:virtio_found_R
set "VIRTIO_DRIVE=R:"
set "VIRTIO_ROOT=R:\"
goto :eof
:virtio_found_S
set "VIRTIO_DRIVE=S:"
set "VIRTIO_ROOT=S:\"
goto :eof
:virtio_found_T
set "VIRTIO_DRIVE=T:"
set "VIRTIO_ROOT=T:\"
goto :eof
:virtio_found_U
set "VIRTIO_DRIVE=U:"
set "VIRTIO_ROOT=U:\"
goto :eof
:virtio_found_V
set "VIRTIO_DRIVE=V:"
set "VIRTIO_ROOT=V:\"
goto :eof
:virtio_found_W
set "VIRTIO_DRIVE=W:"
set "VIRTIO_ROOT=W:\"
goto :eof
:virtio_found_Y
set "VIRTIO_DRIVE=Y:"
set "VIRTIO_ROOT=Y:\"
goto :eof
:virtio_found_Z
set "VIRTIO_DRIVE=Z:"
set "VIRTIO_ROOT=Z:\"
goto :eof
