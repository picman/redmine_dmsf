/*
  Redmine plugin for Document Management System "Features"

  Karel Pičman <karel.picman@kontron.com>

  This file is part of Redmine DMSF plugin.

  Redmine DMSF plugin is free software: you can redistribute it and/or modify it under the terms of the GNU General
  Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any
  later version.

  Redmine DMSF plugin is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
  more details.

  You should have received a copy of the GNU General Public License along with Redmine DMSF plugin. If not, see
  <https://www.gnu.org/licenses/>.
*/

/* Global jsToolBar */

/* Space */
jsToolBar.prototype.elements.dmsf_space = {
  type: 'space'
}

/* DMSF button */
jsToolBar.prototype.elements.dmsf = {
  type: 'button',
  title: 'DMS',
  fn: {
    wiki: function() {
      let This = this;
      this.dmsfMenu(function(macro){
        This.encloseLineSelection('{{' + macro + '(', ')}}');
      });
    }
  }
};

/* DMSF button's popup menu */
jsToolBar.prototype.dmsfMenu = function(fn){
  let menu = $('<ul style="position:absolute;"></ul>');
  for (let i = 0; i < this.dmsfList.length; i++) {
    let reg = new RegExp('^dmsf');
    let item = this.dmsfList[i];
    if(reg.test(item)) {
      let macroItem = $('<div></div>').text(item);
      $('<li></li>').html(macroItem).appendTo(menu).mousedown(function () {
        fn($(this).text());
      });
    }
    else {
      $('<li></li>').html('<hr>').appendTo(menu);
      let macroItem = $('<div></div>').text(item.split(';')[1]);
      $('<li></li>').html(macroItem).appendTo(menu).mousedown(function () {
        window.open('/dmsf/help/wiki_syntax','_blank', 'width=480,height=480');
      });
    }
  }
  $('body').append(menu);
  menu.menu().width(150).position({
    my: 'left top',
    at: 'left bottom',
    of: this.toolNodes['dmsf']
  });
  $(document).on('mousedown', function() {
    menu.remove();
  });
  return false;
};
