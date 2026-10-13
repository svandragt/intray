project('intray', 'vala', 'c', version: '0.1.0', meson_version: '>= 0.59')

executable('intray', 'src/main.vala',
  dependencies: [dependency('gtk4'), dependency('libadwaita-1'), dependency('gio-2.0'), dependency('gio-unix-2.0')],
  install: true)

# The desktop file needs the absolute bindir because the dock may not have ~/.local/bin on its PATH.
configure_file(input: 'data/com.github.svandragt.Intray.desktop.in',
  output: 'com.github.svandragt.Intray.desktop',
  configuration: {'bindir': get_option('prefix') / get_option('bindir')},
  install_dir: get_option('datadir') / 'applications')
install_data('data/com.github.svandragt.Intray.svg',
  install_dir: get_option('datadir') / 'icons/hicolor/scalable/apps')
