# dmgbuild 설정: tools/release.sh가 -D app=... -D bg=...로 불러요.
# 창 내용 660x400pt, 아이콘 128pt. 좌표는 아이콘 중심(왼쪽 위 기준)이고 Resources/dmg/background*.png의
# 화살표·글자 배치와 맞춰져 있어요(배경 원본: Resources/dmg/background-source.html).
import os.path

app = defines.get("app", "build/MacSnow.app")  # noqa: F821 (dmgbuild가 defines를 넣어 줘요)
files = [app]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
background = defines.get("bg", "build/dmg-background.tiff")  # noqa: F821
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (180, 205),
    "Applications": (480, 205),
}
